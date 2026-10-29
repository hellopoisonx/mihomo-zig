// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! End-to-end test: boots the embedded core, pushes real traffic through its
//! mixed inbound, and exercises every exported symbol that a running core can
//! answer.
//!
//! Serial by design: the core is a process-wide singleton, so all assertions
//! run in one test function.

const std = @import("std");
const mihomo = @import("mihomo");

/// translate-c view of ffi/mihomo_abi.h, used only to prove the hand-written
/// extern structs in src/c_api.zig have the same size, alignment and offsets.
const abi = @import("mihomo_abi");

const pointer = "127.0.0.1";
const body_marker = "mihomo-zig-e2e-ok";

var log_seen = std.atomic.Value(bool).init(false);
var traffic_total = std.atomic.Value(u64).init(0);

fn onLog(ctx: ?*anyopaque, level: u8, payload: [*:0]const u8) callconv(.c) void {
    _ = .{ ctx, level, payload };
    // Any delivered log line proves the pump is wired to the core.
    log_seen.store(true, .release);
}

fn onTraffic(
    ctx: ?*anyopaque,
    up_now: u64,
    down_now: u64,
    up_total: u64,
    down_total: u64,
    memory: u64,
) callconv(.c) void {
    _ = .{ ctx, up_now, down_now, memory };
    traffic_total.store(up_total + down_total, .release);
}

/// Minimal HTTP/1.1 origin that answers every request with 200 + `body_marker`.
///
/// Shutdown is driven by a sentinel request rather than a socket close: closing
/// a listening fd does not wake a blocked `accept`, so the loop ends when it
/// reads `stop_line`, which lets the test join the thread deterministically.
const Origin = struct {
    const stop_line = "SENTINEL /stop HTTP/1.1";

    server: std.Io.net.Server,
    io: std.Io,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Origin) void {
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(self.io) catch return;
            self.handle(&stream);
            stream.close(self.io);
        }
    }

    fn handle(self: *Origin, stream: *std.Io.net.Stream) void {
        // Drain the request headers line by line; the body is irrelevant.
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var is_stop = false;
        while (true) {
            const line = reader.interface.takeDelimiterExclusive('\n') catch break;
            if (std.mem.indexOf(u8, line, stop_line) != null) is_stop = true;
            if (line.len == 0 or std.mem.eql(u8, line, "\r")) break;
        }
        if (is_stop) {
            self.stop.store(true, .release);
            return;
        }

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body_marker.len, body_marker },
        ) catch return;
        writer.interface.flush() catch return;
    }
};

/// Minimal UDP DNS responder: answers every A question with `dns_answer_ip`
/// and an empty NOERROR for other types, so the core resolver has a real
/// upstream without touching the network.
const DnsResponder = struct {
    const answer_ip = [4]u8{ 93, 184, 216, 34 };

    socket: std.Io.net.Socket,
    io: std.Io,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *DnsResponder) void {
        var query_buffer: [512]u8 = undefined;
        var response_buffer: [512]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const message = self.socket.receiveTimeout(
                self.io,
                &query_buffer,
                .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } },
            ) catch |err| switch (err) {
                error.Timeout => continue,
                else => return,
            };
            const response = buildResponse(message.data, &response_buffer) orelse continue;
            self.socket.send(self.io, &message.from, response) catch {};
        }
    }

    fn buildResponse(query: []const u8, out: []u8) ?[]const u8 {
        if (query.len < 12) return null;
        if (query[4] != 0 or query[5] != 1) return null; // exactly one question

        var index: usize = 12;
        while (true) {
            if (index >= query.len) return null;
            const label_len = query[index];
            if (label_len == 0) break;
            index += 1 + label_len;
        }
        if (index + 5 > query.len) return null;
        const question_end = index + 5;
        const qtype = (@as(u16, query[index + 1]) << 8) | query[index + 2];
        const has_answer = qtype == 1; // A

        @memcpy(out[0..2], query[0..2]); // transaction id
        @memcpy(out[2..4], &[_]u8{ 0x81, 0x80 }); // QR + RD + RA, NOERROR
        @memcpy(out[4..6], &[_]u8{ 0, 1 }); // QDCOUNT
        const ancount: []const u8 = if (has_answer) &[_]u8{ 0, 1 } else &[_]u8{ 0, 0 };
        @memcpy(out[6..8], ancount); // ANCOUNT
        @memcpy(out[8..12], &[_]u8{ 0, 0, 0, 0 }); // NSCOUNT + ARCOUNT
        @memcpy(out[12..question_end], query[12..question_end]);

        var end = question_end;
        if (has_answer) {
            @memcpy(out[end..][0..2], &[_]u8{ 0xC0, 0x0C }); // name -> question
            @memcpy(out[end + 2 ..][0..2], &[_]u8{ 0, 1 }); // A
            @memcpy(out[end + 4 ..][0..2], &[_]u8{ 0, 1 }); // IN
            @memcpy(out[end + 6 ..][0..4], &[_]u8{ 0, 0, 0, 60 }); // TTL
            @memcpy(out[end + 10 ..][0..2], &[_]u8{ 0, 4 }); // RDLENGTH
            @memcpy(out[end + 12 ..][0..4], &answer_ip);
            end += 16;
        }
        return out[0..end];
    }
};

fn stopOrigin(io: std.Io, origin_port: u16) !void {
    const address = try std.Io.net.IpAddress.parse(pointer, origin_port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("{s}\r\nHost: {s}\r\n\r\n", .{ Origin.stop_line, pointer });
    try writer.interface.flush();
}

fn waitUntil(io: std.Io, comptime predicate: fn () bool, timeout_ms: u32) bool {
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 25) {
        if (predicate()) return true;
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
    }
    return predicate();
}

fn logPredicate() bool {
    return log_seen.load(.acquire);
}

fn trafficPredicate() bool {
    return traffic_total.load(.acquire) > 0;
}

/// Sends one absolute-form HTTP request through the mixed inbound and returns
/// whatever the proxy answered (empty when the connection was rejected).
fn httpViaProxy(
    io: std.Io,
    allocator: std.mem.Allocator,
    proxy_port: u16,
    origin_port: u16,
) ![]u8 {
    const proxy_address = try std.Io.net.IpAddress.parse(pointer, proxy_port);
    var stream = try proxy_address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print(
        "GET http://{s}:{d}/e2e HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ pointer, origin_port, pointer, origin_port },
    );
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);
    reader.interface.appendRemaining(allocator, &response, .limited(64 * 1024)) catch |err| switch (err) {
        // A rejected or reset flow simply yields whatever arrived (usually
        // nothing); the assertions care about the payload, not the error.
        error.ReadFailed, error.StreamTooLong => {},
        else => return err,
    };
    return allocator.dupe(u8, response.items);
}

fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parse(pointer, 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    return server.socket.address.getPort();
}

test "mihomo lifecycle, proxy traffic, queries and teardown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 1. Invalid YAML is rejected with a message.
    try std.testing.expectError(error.Mihomo, mihomo.testConfig(allocator, "not: [valid"));
    try std.testing.expect(mihomo.lastError().len > 0);

    // 2. Origin server on an ephemeral port.
    const origin_address = try std.Io.net.IpAddress.parse(pointer, 0);
    var origin = Origin{
        .server = try origin_address.listen(io, .{ .reuse_address = true }),
        .io = io,
    };
    const origin_port = origin.server.socket.address.getPort();

    var origin_thread = try std.Thread.spawn(.{}, Origin.run, .{&origin});
    // The sentinel request ends the loop, so join can never block on accept.
    defer {
        stopOrigin(io, origin_port) catch {};
        origin_thread.join();
        origin.server.deinit(io);
    }

    // 3. Free ports for the mixed inbound and a local DNS upstream, then a
    // config that uses both.
    const mixed_port = try freePort(io);

    const dns_address = try std.Io.net.IpAddress.parse(pointer, 0);
    var dns_responder = DnsResponder{
        .socket = try dns_address.bind(io, .{ .mode = .dgram }),
        .io = io,
    };
    const dns_port = dns_responder.socket.address.getPort();
    var dns_thread = try std.Thread.spawn(.{}, DnsResponder.run, .{&dns_responder});
    defer {
        dns_responder.stop.store(true, .release);
        dns_thread.join();
        dns_responder.socket.close(io);
    }

    const config = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\log-level: debug
        \\mode: rule
        \\dns:
        \\  enable: true
        \\  nameserver:
        \\    - {s}:{d}
        \\proxy-groups:
        \\  - name: E2E
        \\    type: select
        \\    proxies:
        \\      - DIRECT
        \\      - REJECT
        \\rules:
        \\  - MATCH,E2E
        \\
    , .{ mixed_port, pointer, dns_port });
    defer allocator.free(config);

    const home_dir = try std.fmt.allocPrint(allocator, "/tmp/mihomo-zig-e2e-{d}", .{std.os.linux.getpid()});
    defer allocator.free(home_dir);

    // 4. Start + callbacks.
    mihomo.setLogCallback(onLog, null);
    mihomo.setTrafficCallback(onTraffic, null);
    defer {
        mihomo.setTrafficCallback(null, null);
        mihomo.setLogCallback(null, null);
    }

    try mihomo.start(allocator, home_dir, config);
    defer mihomo.stop() catch {};
    try std.testing.expectError(error.Mihomo, mihomo.start(allocator, home_dir, config));
    try std.testing.expect(std.mem.indexOf(u8, mihomo.lastError(), "already started") != null);

    // 5. Log pump.
    try std.testing.expect(waitUntil(io, logPredicate, 5000));

    // 6. Real HTTP request through the mixed inbound.
    const first = try httpViaProxy(io, allocator, mixed_port, origin_port);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, body_marker) != null);

    // 7. Traffic counters observed by the pump.
    try std.testing.expect(waitUntil(io, trafficPredicate, 5000));

    // 8. Typed queries: proxies, groups, rules, connections, providers.
    var proxies = try mihomo.proxies(allocator);
    defer proxies.deinit();

    var direct_proxy: ?mihomo.Proxy = null;
    var e2e_group: ?mihomo.Proxy = null;
    for (proxies.value) |entry| {
        if (std.mem.eql(u8, entry.name, "DIRECT")) direct_proxy = entry;
        if (std.mem.eql(u8, entry.name, "E2E")) e2e_group = entry;
    }
    try std.testing.expect(direct_proxy != null);
    try std.testing.expect(e2e_group != null);

    const direct = direct_proxy.?;
    try std.testing.expect(!direct.is_group);
    try std.testing.expectEqualStrings("Direct", direct.kind);
    try std.testing.expect(direct.udp);
    try std.testing.expectEqual(@as(usize, 0), direct.members.len);

    const group = e2e_group.?;
    try std.testing.expect(group.is_group);
    try std.testing.expectEqualStrings("Selector", group.kind);
    try std.testing.expectEqualStrings("DIRECT", group.now);
    try std.testing.expectEqual(@as(usize, 2), group.members.len);
    try std.testing.expectEqualStrings("DIRECT", group.members[0]);
    try std.testing.expectEqualStrings("REJECT", group.members[1]);

    var single = try mihomo.proxy(allocator, "E2E");
    defer single.deinit();
    try std.testing.expectEqualStrings("E2E", single.value.name);
    try std.testing.expect(single.value.is_group);

    var groups = try mihomo.groups(allocator);
    defer groups.deinit();
    // mihomo always adds a built-in GLOBAL selector next to configured groups.
    try std.testing.expect(groups.value.len >= 2);
    var saw_e2e_group = false;
    var saw_global_group = false;
    for (groups.value) |entry| {
        try std.testing.expect(entry.is_group);
        if (std.mem.eql(u8, entry.name, "E2E")) saw_e2e_group = true;
        if (std.mem.eql(u8, entry.name, "GLOBAL")) saw_global_group = true;
    }
    try std.testing.expect(saw_e2e_group);
    try std.testing.expect(saw_global_group);

    var rules = try mihomo.rules(allocator);
    defer rules.deinit();
    try std.testing.expect(rules.value.len >= 1);
    var match_rule: ?mihomo.Rule = null;
    for (rules.value) |rule| {
        if (std.mem.eql(u8, rule.rule_type, "Match")) match_rule = rule;
    }
    try std.testing.expect(match_rule != null);
    try std.testing.expectEqualStrings("E2E", match_rule.?.proxy);
    try std.testing.expectEqual(@as(i32, -1), match_rule.?.size);
    try std.testing.expect(match_rule.?.has_extra);

    var snapshot = try mihomo.connections(allocator);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.value.upload_total + snapshot.value.download_total > 0);
    for (snapshot.value.connections) |connection| {
        try std.testing.expect(connection.id.len > 0);
        try std.testing.expectEqualStrings("tcp", connection.network);
        try std.testing.expect(connection.source_port != 0);
        try std.testing.expect(connection.destination_port != 0);
        try std.testing.expect(connection.chains.len >= 1);
    }

    var providers = try mihomo.providers(allocator);
    defer providers.deinit();
    // Each proxy group gets a compatible provider; "default" holds every proxy.
    try std.testing.expect(providers.value.len >= 2);
    var saw_e2e_provider = false;
    for (providers.value) |provider| {
        try std.testing.expectEqualStrings("Proxy", provider.provider_type);
        try std.testing.expect(provider.vehicle_type.len > 0);
        if (std.mem.eql(u8, provider.name, "E2E")) {
            saw_e2e_provider = true;
            try std.testing.expect(provider.proxy_count >= 2);
        }
    }
    try std.testing.expect(saw_e2e_provider);

    // The JSON escape hatch stays byte-identical to the REST handlers.
    const proxies_json = try mihomo.getProxiesJson(allocator);
    defer allocator.free(proxies_json);
    try std.testing.expect(std.mem.indexOf(u8, proxies_json, "\"DIRECT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, proxies_json, "\"E2E\"") != null);

    // 9. Selector switch: REJECT drops the flow, DIRECT restores it.
    try mihomo.selectProxy(allocator, "E2E", "REJECT");
    const rejected = try httpViaProxy(io, allocator, mixed_port, origin_port);
    defer allocator.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, body_marker) == null);

    try mihomo.selectProxy(allocator, "E2E", "DIRECT");
    const restored = try httpViaProxy(io, allocator, mixed_port, origin_port);
    defer allocator.free(restored);
    try std.testing.expect(std.mem.indexOf(u8, restored, body_marker) != null);

    // Non-selector targets are rejected with the upstream message.
    try std.testing.expectError(error.Mihomo, mihomo.selectProxy(allocator, "DIRECT", "REJECT"));
    try std.testing.expect(std.mem.indexOf(u8, mihomo.lastError(), "Must be a Selector") != null);

    // 10. Typed latency probes; the history lands in the proxy record.
    const origin_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/e2e", .{ pointer, origin_port });
    defer allocator.free(origin_url);

    const delay = try mihomo.urlTest(allocator, "DIRECT", origin_url, 5000, "200");
    try std.testing.expect(delay > 0);

    var group_delays = try mihomo.groupUrlTest(allocator, "E2E", origin_url, 5000, "200");
    defer group_delays.deinit();
    try std.testing.expectEqual(@as(usize, 1), group_delays.value.len);
    try std.testing.expectEqualStrings("DIRECT", group_delays.value[0].name);
    try std.testing.expect(group_delays.value[0].delay_ms > 0);

    var probed = try mihomo.proxies(allocator);
    defer probed.deinit();
    var probed_direct = false;
    for (probed.value) |entry| {
        if (!std.mem.eql(u8, entry.name, "DIRECT")) continue;
        probed_direct = true;
        try std.testing.expect(entry.alive);
        try std.testing.expect(entry.history.len > 0);
        try std.testing.expect(entry.history[entry.history.len - 1].delay_ms > 0);
    }
    try std.testing.expect(probed_direct);

    // 11. DNS reaches the local responder; the typed record exposes it.
    var dns = try mihomo.dnsQuery(allocator, "example.com", "A");
    defer dns.deinit();
    try std.testing.expectEqual(@as(i32, 0), dns.value.status);
    try std.testing.expectEqual(@as(usize, 1), dns.value.answers.len);
    try std.testing.expectEqual(@as(u16, 1), dns.value.answers[0].record_type);
    try std.testing.expectEqualStrings("93.184.216.34", dns.value.answers[0].data);
    try std.testing.expect(dns.value.answers[0].ttl > 0);

    const dns_json = try mihomo.dnsQueryJson(allocator, "example.com", "A");
    defer allocator.free(dns_json);
    try std.testing.expect(std.mem.indexOf(u8, dns_json, "93.184.216.34") != null);

    try std.testing.expectError(error.Mihomo, mihomo.dnsQuery(allocator, "example.com", "BOGUS"));
    try std.testing.expect(mihomo.lastError().len > 0);

    // 12. Remaining symbols: version banner, single-proxy lookup, provider and
    // connection error paths, full reload, and the close-all no-op.
    try std.testing.expect(std.mem.indexOf(u8, mihomo.version(), "zig-ffi-dev") != null);
    try std.testing.expect(mihomo.buildTime().len > 0);

    try std.testing.expectError(error.Mihomo, mihomo.proxy(allocator, "NO-SUCH-PROXY"));
    try std.testing.expect(std.mem.indexOf(u8, mihomo.lastError(), "proxy not found") != null);
    try std.testing.expectError(error.Mihomo, mihomo.closeConnection(allocator, "no-such-id"));
    try std.testing.expectError(error.Mihomo, mihomo.updateProvider(allocator, "no-such-provider"));
    try std.testing.expectError(error.Mihomo, mihomo.healthcheckProvider(allocator, "no-such-provider"));

    try mihomo.reload(allocator, config);
    var after_reload = try mihomo.proxies(allocator);
    defer after_reload.deinit();
    try std.testing.expect(after_reload.value.len >= 3);

    mihomo.closeAllConnections();

    // 13. Teardown stops the inbound for real.
    mihomo.setTrafficCallback(null, null);
    mihomo.setLogCallback(null, null);
    try mihomo.stop();
    try std.testing.expectError(error.Mihomo, mihomo.stop());

    const after_stop_address = try std.Io.net.IpAddress.parse(pointer, mixed_port);
    if (after_stop_address.connect(io, .{ .mode = .stream })) |stream_value| {
        var stream = stream_value;
        stream.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}

    // 14. A stopped core can boot again on the same home dir and port.
    try mihomo.start(allocator, home_dir, config);
    var restarted = try mihomo.proxies(allocator);
    defer restarted.deinit();
    try std.testing.expect(restarted.value.len >= 3);
    try mihomo.stop();
}

/// Compares a hand-written extern struct with the C record it mirrors: same
/// size, alignment, field count and per-field offsets.
fn expectMirrored(comptime Zig: type, comptime Ref: type) !void {
    try std.testing.expectEqual(@sizeOf(Ref), @sizeOf(Zig));
    try std.testing.expectEqual(@alignOf(Ref), @alignOf(Zig));

    const zig_names = @typeInfo(Zig).@"struct".field_names;
    try std.testing.expectEqual(@typeInfo(Ref).@"struct".field_names.len, zig_names.len);
    inline for (zig_names) |name| {
        try std.testing.expectEqual(@offsetOf(Ref, name), @offsetOf(Zig, name));
    }
}

test "C ABI records mirror ffi/mihomo_abi.h" {
    try expectMirrored(mihomo.c_api.DelaySample, abi.mihomo_delay_sample);
    try expectMirrored(mihomo.c_api.ProxyInfo, abi.mihomo_proxy_info);
    try expectMirrored(mihomo.c_api.ConnectionInfo, abi.mihomo_connection_info);
    try expectMirrored(mihomo.c_api.ConnectionsSnapshot, abi.mihomo_connections_snapshot);
    try expectMirrored(mihomo.c_api.RuleInfo, abi.mihomo_rule_info);
    try expectMirrored(mihomo.c_api.ProviderInfo, abi.mihomo_provider_info);
    try expectMirrored(mihomo.c_api.DelayEntry, abi.mihomo_delay_entry);
    try expectMirrored(mihomo.c_api.DnsRecord, abi.mihomo_dns_record);
    try expectMirrored(mihomo.c_api.DnsResult, abi.mihomo_dns_result);
}

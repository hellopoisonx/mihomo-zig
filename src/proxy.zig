// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Proxy and proxy-group records, queries, latency probes and selection.

const std = @import("std");
const c = @import("c_api.zig");
const copy = @import("copy.zig");
const errors = @import("error.zig");
const owned = @import("owned.zig");

const Error = errors.Error;

pub const DelaySample = struct {
    time_unix_ms: i64,
    /// 0 when that probe failed.
    delay_ms: u16,
};

/// One outbound proxy or proxy group. Fields that do not apply are empty,
/// never null; `is_group` decides whether `members` is meaningful.
pub const Proxy = struct {
    name: []const u8,
    kind: []const u8,
    now: []const u8,
    provider_name: []const u8,
    dialer_proxy: []const u8,
    interface_name: []const u8,
    icon: []const u8,
    empty_fallback: []const u8,
    routing_mark: i32,
    /// Last delay for the default test URL; null when never probed there.
    delay_ms: ?u16,
    is_group: bool,
    udp: bool,
    xudp: bool,
    uot: bool,
    tfo: bool,
    mptcp: bool,
    smux: bool,
    alive: bool,
    hidden: bool,
    members: []const []const u8,
    /// Recent latency samples (any test URL), oldest first.
    history: []const DelaySample,
};

pub const DelayEntry = struct {
    name: []const u8,
    delay_ms: u16,
};

fn copySamples(arena: std.mem.Allocator, ptr: ?[*]const c.DelaySample, len: u32) Error![]const DelaySample {
    if (len == 0) return &.{};
    const source = ptr orelse return &.{};
    const items = try arena.alloc(DelaySample, len);
    for (items, 0..) |*item, i| {
        item.* = .{
            .time_unix_ms = source[i].time_unix_ms,
            .delay_ms = copy.delayToU16(source[i].delay_ms),
        };
    }
    return items;
}

fn convertProxy(arena: std.mem.Allocator, raw: *const c.ProxyInfo) Error!Proxy {
    return .{
        .name = try copy.string(arena, raw.name),
        .kind = try copy.string(arena, raw.kind),
        .now = try copy.string(arena, raw.now),
        .provider_name = try copy.string(arena, raw.provider_name),
        .dialer_proxy = try copy.string(arena, raw.dialer_proxy),
        .interface_name = try copy.string(arena, raw.interface_name),
        .icon = try copy.string(arena, raw.icon),
        .empty_fallback = try copy.string(arena, raw.empty_fallback),
        .routing_mark = raw.routing_mark,
        .delay_ms = if (raw.delay_ms < 0) null else copy.delayToU16(@intCast(raw.delay_ms)),
        .is_group = raw.is_group != 0,
        .udp = raw.udp != 0,
        .xudp = raw.xudp != 0,
        .uot = raw.uot != 0,
        .tfo = raw.tfo != 0,
        .mptcp = raw.mptcp != 0,
        .smux = raw.smux != 0,
        .alive = raw.alive != 0,
        .hidden = raw.hidden != 0,
        .members = try copy.stringList(arena, raw.members, raw.members_len),
        .history = try copySamples(arena, raw.history, raw.history_len),
    };
}

fn convertDelayEntry(arena: std.mem.Allocator, raw: *const c.DelayEntry) Error!DelayEntry {
    return .{
        .name = try copy.string(arena, raw.name),
        .delay_ms = copy.delayToU16(@intCast(raw.delay_ms)),
    };
}

/// Every proxy and proxy group, sorted by name.
pub fn proxies(allocator: std.mem.Allocator) Error!owned.Owned([]const Proxy) {
    return owned.fetchList(c.ProxyInfo, Proxy, allocator, c.mihomo_get_proxies, convertProxy);
}

/// One proxy by name.
pub fn proxy(allocator: std.mem.Allocator, name: []const u8) Error!owned.Owned(Proxy) {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var raw: ?*c.ProxyInfo = null;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_get_proxy(name_z.ptr, &raw, &err_ptr), err_ptr);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const record = raw orelse return error.Mihomo;
    defer c.mihomo_free(@ptrCast(record));
    // Convert before building the result: struct fields are evaluated in
    // source order, so `.arena` must be copied after the arena is filled.
    const value = try convertProxy(arena.allocator(), record);
    return .{ .arena = arena, .value = value };
}

/// Proxy groups only, with `members` filled in.
pub fn groups(allocator: std.mem.Allocator) Error!owned.Owned([]const Proxy) {
    return owned.fetchList(c.ProxyInfo, Proxy, allocator, c.mihomo_get_groups, convertProxy);
}

/// Single-proxy latency test. `expected` is a status range list such as
/// "200" or "200,204"; null means any status.
pub fn urlTest(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    timeout_ms: u32,
    expected: ?[]const u8,
) Error!u16 {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const url_z = try allocator.dupeSentinel(u8, url, 0);
    defer allocator.free(url_z);
    const expected_z = if (expected) |e| try allocator.dupeSentinel(u8, e, 0) else null;
    defer if (expected_z) |e| allocator.free(e);

    var delay: i32 = -1;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(
        c.mihomo_url_test(name_z.ptr, url_z.ptr, timeout_ms, if (expected_z) |e| e.ptr else null, &delay, &err_ptr),
        err_ptr,
    );
    if (delay <= 0) return error.Mihomo;
    return std.math.cast(u16, delay) orelse return error.Mihomo;
}

/// Group latency test; failed members are omitted, like the upstream handler.
pub fn groupUrlTest(
    allocator: std.mem.Allocator,
    group: []const u8,
    url: []const u8,
    timeout_ms: u32,
    expected: ?[]const u8,
) Error!owned.Owned([]const DelayEntry) {
    const group_z = try allocator.dupeSentinel(u8, group, 0);
    defer allocator.free(group_z);
    const url_z = try allocator.dupeSentinel(u8, url, 0);
    defer allocator.free(url_z);
    const expected_z = if (expected) |e| try allocator.dupeSentinel(u8, e, 0) else null;
    defer if (expected_z) |e| allocator.free(e);

    var raw: ?[*]c.DelayEntry = null;
    var raw_len: u32 = 0;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(
        c.mihomo_group_url_test(
            group_z.ptr,
            url_z.ptr,
            timeout_ms,
            if (expected_z) |e| e.ptr else null,
            &raw,
            &raw_len,
            &err_ptr,
        ),
        err_ptr,
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const records = raw orelse return .{ .arena = arena, .value = &.{} };
    defer c.mihomo_free(@ptrCast(records));

    const items = try arena_allocator.alloc(DelayEntry, raw_len);
    for (items, 0..) |*item, i| item.* = try convertDelayEntry(arena_allocator, &records[i]);
    return .{ .arena = arena, .value = items };
}

/// Persists `name` as the selection of a Selector/URLTest group.
pub fn selectProxy(allocator: std.mem.Allocator, group: []const u8, name: []const u8) Error!void {
    const group_z = try allocator.dupeSentinel(u8, group, 0);
    defer allocator.free(group_z);
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_select_proxy(group_z.ptr, name_z.ptr, &err_ptr), err_ptr);
}

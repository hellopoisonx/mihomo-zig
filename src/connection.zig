// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Connection snapshot and connection operations.

const std = @import("std");
const c = @import("c_api.zig");
const copy = @import("copy.zig");
const errors = @import("error.zig");
const owned = @import("owned.zig");

const Error = errors.Error;

pub const Connection = struct {
    id: []const u8,
    network: []const u8,
    inbound_type: []const u8,
    source_ip: []const u8,
    destination_ip: []const u8,
    host: []const u8,
    inbound_name: []const u8,
    inbound_user: []const u8,
    dns_mode: []const u8,
    process: []const u8,
    process_path: []const u8,
    special_proxy: []const u8,
    special_rules: []const u8,
    sniff_host: []const u8,
    remote_destination: []const u8,
    rule: []const u8,
    rule_payload: []const u8,
    chains: []const []const u8,
    provider_chains: []const []const u8,
    upload: i64,
    download: i64,
    start_unix_ms: ?i64,
    uid: u32,
    source_port: u16,
    destination_port: u16,
    inbound_port: u16,
    dscp: u8,
};

pub const Connections = struct {
    upload_total: i64,
    download_total: i64,
    /// Process RSS in bytes.
    memory: u64,
    connections: []const Connection,
};

fn convertConnection(arena: std.mem.Allocator, raw: *const c.ConnectionInfo) Error!Connection {
    return .{
        .id = try copy.string(arena, raw.id),
        .network = try copy.string(arena, raw.network),
        .inbound_type = try copy.string(arena, raw.inbound_type),
        .source_ip = try copy.string(arena, raw.source_ip),
        .destination_ip = try copy.string(arena, raw.destination_ip),
        .host = try copy.string(arena, raw.host),
        .inbound_name = try copy.string(arena, raw.inbound_name),
        .inbound_user = try copy.string(arena, raw.inbound_user),
        .dns_mode = try copy.string(arena, raw.dns_mode),
        .process = try copy.string(arena, raw.process),
        .process_path = try copy.string(arena, raw.process_path),
        .special_proxy = try copy.string(arena, raw.special_proxy),
        .special_rules = try copy.string(arena, raw.special_rules),
        .sniff_host = try copy.string(arena, raw.sniff_host),
        .remote_destination = try copy.string(arena, raw.remote_destination),
        .rule = try copy.string(arena, raw.rule),
        .rule_payload = try copy.string(arena, raw.rule_payload),
        .chains = try copy.stringList(arena, raw.chains, raw.chains_len),
        .provider_chains = try copy.stringList(arena, raw.provider_chains, raw.provider_chains_len),
        .upload = raw.upload,
        .download = raw.download,
        .start_unix_ms = if (raw.start_unix_ms == 0) null else raw.start_unix_ms,
        .uid = raw.uid,
        .source_port = raw.source_port,
        .destination_port = raw.destination_port,
        .inbound_port = raw.inbound_port,
        .dscp = raw.dscp,
    };
}

fn convertConnections(arena: std.mem.Allocator, raw: *const c.ConnectionsSnapshot) Error!Connections {
    var list: []const Connection = &.{};
    if (raw.connections) |records| {
        const items = try arena.alloc(Connection, raw.connections_len);
        for (items, 0..) |*item, i| item.* = try convertConnection(arena, &records[i]);
        list = items;
    }
    return .{
        .upload_total = raw.upload_total,
        .download_total = raw.download_total,
        .memory = raw.memory,
        .connections = list,
    };
}

/// Live connection table plus process-wide totals.
pub fn connections(allocator: std.mem.Allocator) Error!owned.Owned(Connections) {
    var raw: ?*c.ConnectionsSnapshot = null;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_get_connections(&raw, &err_ptr), err_ptr);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const record = raw orelse return error.Mihomo;
    defer c.mihomo_free(@ptrCast(record));
    const value = try convertConnections(arena.allocator(), record);
    return .{ .arena = arena, .value = value };
}

pub fn closeConnection(allocator: std.mem.Allocator, id: []const u8) Error!void {
    const id_z = try allocator.dupeSentinel(u8, id, 0);
    defer allocator.free(id_z);

    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_close_connection(id_z.ptr, &err_ptr), err_ptr);
}

pub fn closeAllConnections() void {
    c.mihomo_close_all_connections();
}

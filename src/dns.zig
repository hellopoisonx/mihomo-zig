// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! DNS query records and the resolver call.

const std = @import("std");
const c = @import("c_api.zig");
const copy = @import("copy.zig");
const errors = @import("error.zig");
const owned = @import("owned.zig");

const Error = errors.Error;

pub const DnsRecord = struct {
    name: []const u8,
    data: []const u8,
    ttl: u32,
    record_type: u16,
};

pub const DnsResult = struct {
    /// DNS RCODE.
    status: i32,
    truncated: bool,
    recursion_desired: bool,
    recursion_available: bool,
    authenticated_data: bool,
    checking_disabled: bool,
    answers: []const DnsRecord,
    authority: []const DnsRecord,
    additional: []const DnsRecord,
};

fn convertDnsRecord(arena: std.mem.Allocator, raw: *const c.DnsRecord) Error!DnsRecord {
    return .{
        .name = try copy.string(arena, raw.name),
        .data = try copy.string(arena, raw.data),
        .ttl = raw.ttl,
        .record_type = raw.record_type,
    };
}

fn convertDnsSection(arena: std.mem.Allocator, ptr: ?[*]const c.DnsRecord, len: u32) Error![]const DnsRecord {
    if (len == 0) return &.{};
    const source = ptr orelse return &.{};
    const items = try arena.alloc(DnsRecord, len);
    for (items, 0..) |*item, i| item.* = try convertDnsRecord(arena, &source[i]);
    return items;
}

fn convertDnsResult(arena: std.mem.Allocator, raw: *const c.DnsResult) Error!DnsResult {
    return .{
        .status = raw.status,
        .truncated = raw.truncated != 0,
        .recursion_desired = raw.recursion_desired != 0,
        .recursion_available = raw.recursion_available != 0,
        .authenticated_data = raw.authenticated_data != 0,
        .checking_disabled = raw.checking_disabled != 0,
        .answers = try convertDnsSection(arena, raw.answers, raw.answers_len),
        .authority = try convertDnsSection(arena, raw.authority, raw.authority_len),
        .additional = try convertDnsSection(arena, raw.additional, raw.additional_len),
    };
}

/// Resolves `name` through the core resolver.
pub fn dnsQuery(allocator: std.mem.Allocator, name: []const u8, type_str: ?[]const u8) Error!owned.Owned(DnsResult) {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const type_z = if (type_str) |t| try allocator.dupeSentinel(u8, t, 0) else null;
    defer if (type_z) |t| allocator.free(t);

    var raw: ?*c.DnsResult = null;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(
        c.mihomo_dns_query(name_z.ptr, if (type_z) |t| t.ptr else null, &raw, &err_ptr),
        err_ptr,
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const record = raw orelse return error.Mihomo;
    defer c.mihomo_free(@ptrCast(record));
    const value = try convertDnsResult(arena.allocator(), record);
    return .{ .arena = arena, .value = value };
}

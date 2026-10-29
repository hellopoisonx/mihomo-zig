// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Proxy provider records, queries and refreshes.

const std = @import("std");
const c = @import("c_api.zig");
const copy = @import("copy.zig");
const errors = @import("error.zig");
const owned = @import("owned.zig");

const Error = errors.Error;

pub const Provider = struct {
    name: []const u8,
    provider_type: []const u8,
    vehicle_type: []const u8,
    test_url: []const u8,
    updated_at_unix_ms: ?i64,
    proxy_count: u32,
};

fn convertProvider(arena: std.mem.Allocator, raw: *const c.ProviderInfo) Error!Provider {
    return .{
        .name = try copy.string(arena, raw.name),
        .provider_type = try copy.string(arena, raw.provider_type),
        .vehicle_type = try copy.string(arena, raw.vehicle_type),
        .test_url = try copy.string(arena, raw.test_url),
        .updated_at_unix_ms = if (raw.updated_at_unix_ms == 0) null else raw.updated_at_unix_ms,
        .proxy_count = raw.proxy_count,
    };
}

/// Proxy providers, sorted by name.
pub fn providers(allocator: std.mem.Allocator) Error!owned.Owned([]const Provider) {
    return owned.fetchList(c.ProviderInfo, Provider, allocator, c.mihomo_get_providers, convertProvider);
}

pub fn updateProvider(allocator: std.mem.Allocator, name: []const u8) Error!void {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_update_provider(name_z.ptr, &err_ptr), err_ptr);
}

pub fn healthcheckProvider(allocator: std.mem.Allocator, name: []const u8) Error!void {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(c.mihomo_healthcheck_provider(name_z.ptr, &err_ptr), err_ptr);
}

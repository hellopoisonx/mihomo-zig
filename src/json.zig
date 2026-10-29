// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! JSON escape hatch: byte-identical to the upstream REST handlers.
//!
//! Use these only for fields the typed records do not model (provider
//! subscription info, per-URL histories, DNS question sections).

const std = @import("std");
const c = @import("c_api.zig");
const errors = @import("error.zig");

const Error = errors.Error;

/// Takes ownership of a JSON string returned by the library, copying it into
/// `allocator` and freeing the C allocation.
fn takeJson(allocator: std.mem.Allocator, json_ptr: ?[*:0]u8, err_ptr: ?[*:0]u8) Error![]u8 {
    const ptr = json_ptr orelse return errors.captureErr(err_ptr);
    defer c.mihomo_free(@ptrCast(ptr));
    return allocator.dupe(u8, std.mem.span(ptr));
}

pub fn getProxiesJson(allocator: std.mem.Allocator) Error![]u8 {
    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_proxies_json(&err_ptr), err_ptr);
}

pub fn getProxyJson(allocator: std.mem.Allocator, name: []const u8) Error![]u8 {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_proxy_json(name_z.ptr, &err_ptr), err_ptr);
}

pub fn getGroupsJson(allocator: std.mem.Allocator) Error![]u8 {
    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_groups_json(&err_ptr), err_ptr);
}

pub fn getConnectionsJson(allocator: std.mem.Allocator) Error![]u8 {
    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_connections_json(&err_ptr), err_ptr);
}

pub fn getRulesJson(allocator: std.mem.Allocator) Error![]u8 {
    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_rules_json(&err_ptr), err_ptr);
}

pub fn getProvidersJson(allocator: std.mem.Allocator) Error![]u8 {
    var err_ptr: ?[*:0]u8 = null;
    return takeJson(allocator, c.mihomo_get_providers_json(&err_ptr), err_ptr);
}

pub fn urlTestJson(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    timeout_ms: u32,
    expected: ?[]const u8,
) Error![]u8 {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const url_z = try allocator.dupeSentinel(u8, url, 0);
    defer allocator.free(url_z);
    const expected_z = if (expected) |e| try allocator.dupeSentinel(u8, e, 0) else null;
    defer if (expected_z) |e| allocator.free(e);

    var err_ptr: ?[*:0]u8 = null;
    return takeJson(
        allocator,
        c.mihomo_url_test_json(name_z.ptr, url_z.ptr, timeout_ms, if (expected_z) |e| e.ptr else null, &err_ptr),
        err_ptr,
    );
}

pub fn groupUrlTestJson(
    allocator: std.mem.Allocator,
    group: []const u8,
    url: []const u8,
    timeout_ms: u32,
    expected: ?[]const u8,
) Error![]u8 {
    const group_z = try allocator.dupeSentinel(u8, group, 0);
    defer allocator.free(group_z);
    const url_z = try allocator.dupeSentinel(u8, url, 0);
    defer allocator.free(url_z);
    const expected_z = if (expected) |e| try allocator.dupeSentinel(u8, e, 0) else null;
    defer if (expected_z) |e| allocator.free(e);

    var err_ptr: ?[*:0]u8 = null;
    return takeJson(
        allocator,
        c.mihomo_group_url_test_json(group_z.ptr, url_z.ptr, timeout_ms, if (expected_z) |e| e.ptr else null, &err_ptr),
        err_ptr,
    );
}

pub fn dnsQueryJson(allocator: std.mem.Allocator, name: []const u8, type_str: ?[]const u8) Error![]u8 {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const type_z = if (type_str) |t| try allocator.dupeSentinel(u8, t, 0) else null;
    defer if (type_z) |t| allocator.free(t);

    var err_ptr: ?[*:0]u8 = null;
    return takeJson(
        allocator,
        c.mihomo_dns_query_json(name_z.ptr, if (type_z) |t| t.ptr else null, &err_ptr),
        err_ptr,
    );
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Process lifecycle, version banner and push callbacks.

const std = @import("std");
const c = @import("c_api.zig");
const errors = @import("error.zig");
const Error = errors.Error;

fn staticString(ptr: [*:0]const u8) []const u8 {
    return std.mem.span(ptr);
}

pub fn version() []const u8 {
    return staticString(c.mihomo_version());
}

pub fn buildTime() []const u8 {
    return staticString(c.mihomo_build_time());
}

/// Boots the core. `home_dir` may be null to keep the current home directory.
/// Fails with "already started" when the core is already running: restart with
/// `stop` + `start`.
pub fn start(allocator: std.mem.Allocator, home_dir: ?[]const u8, config_yaml: []const u8) Error!void {
    const yaml_z = try allocator.dupeSentinel(u8, config_yaml, 0);
    defer allocator.free(yaml_z);

    var home_z: ?[:0]u8 = null;
    defer if (home_z) |h| allocator.free(h);
    if (home_dir) |h| home_z = try allocator.dupeSentinel(u8, h, 0);

    var err_ptr: ?[*:0]u8 = null;
    const status = c.mihomo_start(
        if (home_z) |h| h.ptr else null,
        yaml_z.ptr,
        &err_ptr,
    );
    try errors.checkStatus(status, err_ptr);
}

/// Re-applies a whole configuration document to a running core.
pub fn reload(allocator: std.mem.Allocator, config_yaml: []const u8) Error!void {
    const yaml_z = try allocator.dupeSentinel(u8, config_yaml, 0);
    defer allocator.free(yaml_z);

    var err_ptr: ?[*:0]u8 = null;
    const status = c.mihomo_reload(yaml_z.ptr, &err_ptr);
    try errors.checkStatus(status, err_ptr);
}

/// Tears the core down. Callbacks stop firing before this returns.
pub fn stop() Error!void {
    var err_ptr: ?[*:0]u8 = null;
    const status = c.mihomo_stop(&err_ptr);
    try errors.checkStatus(status, err_ptr);
}

/// Validates a configuration document without applying it (`mihomo -t`).
pub fn testConfig(allocator: std.mem.Allocator, config_yaml: []const u8) Error!void {
    const yaml_z = try allocator.dupeSentinel(u8, config_yaml, 0);
    defer allocator.free(yaml_z);

    var err_ptr: ?[*:0]u8 = null;
    const status = c.mihomo_test_config(yaml_z.ptr, &err_ptr);
    try errors.checkStatus(status, err_ptr);
}

/// Registers a log sink; `null` unregisters. Blocks until an unregistered pump
/// has fully drained.
pub fn setLogCallback(cb: ?c.LogCallback, ctx: ?*anyopaque) void {
    c.mihomo_set_log_callback(cb, ctx);
}

/// Registers a 1 Hz traffic heartbeat; `null` unregisters.
pub fn setTrafficCallback(cb: ?c.TrafficCallback, ctx: ?*anyopaque) void {
    c.mihomo_set_traffic_callback(cb, ctx);
}

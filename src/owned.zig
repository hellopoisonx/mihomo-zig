// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Arena ownership for typed query results.
//!
//! A typed query copies its C records into one arena; `Owned(T)` keeps that
//! arena next to the value so a single `deinit()` releases every string and
//! slice at once.

const std = @import("std");
const c = @import("c_api.zig");
const errors = @import("error.zig");

/// A value plus the arena that owns every string and slice inside it.
/// Treat it as move-only: call `deinit()` exactly once.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Runs a list export and copies every record with `convert`.
pub fn fetchList(
    comptime Raw: type,
    comptime Out: type,
    allocator: std.mem.Allocator,
    call: *const fn (?*?[*]Raw, ?*u32, ?*?[*:0]u8) callconv(.c) c_int,
    convert: *const fn (std.mem.Allocator, *const Raw) errors.Error!Out,
) errors.Error!Owned([]const Out) {
    var raw: ?[*]Raw = null;
    var raw_len: u32 = 0;
    var err_ptr: ?[*:0]u8 = null;
    try errors.checkStatus(call(&raw, &raw_len, &err_ptr), err_ptr);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const records = raw orelse return .{ .arena = arena, .value = &.{} };
    defer c.mihomo_free(@ptrCast(records));

    const items = try arena_allocator.alloc(Out, raw_len);
    for (items, 0..) |*item, i| item.* = try convert(arena_allocator, &records[i]);
    return .{ .arena = arena, .value = items };
}

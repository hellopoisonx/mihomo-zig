// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Copies C record fields into arena-owned Zig values.

const std = @import("std");
const errors = @import("error.zig");

pub fn string(arena: std.mem.Allocator, ptr: [*:0]const u8) errors.Error![]const u8 {
    return arena.dupe(u8, std.mem.span(ptr));
}

pub fn stringList(arena: std.mem.Allocator, ptr: ?[*]const [*:0]const u8, len: u32) errors.Error![]const []const u8 {
    if (len == 0) return &.{};
    const source = ptr orelse return &.{};
    const items = try arena.alloc([]const u8, len);
    for (items, 0..) |*item, i| item.* = try string(arena, source[i]);
    return items;
}

pub fn delayToU16(value: u32) u16 {
    return std.math.cast(u16, value) orelse std.math.maxInt(u16);
}

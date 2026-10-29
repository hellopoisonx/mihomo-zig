// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Routing rule records and queries.

const std = @import("std");
const c = @import("c_api.zig");
const copy = @import("copy.zig");
const errors = @import("error.zig");
const owned = @import("owned.zig");

const Error = errors.Error;

pub const Rule = struct {
    rule_type: []const u8,
    payload: []const u8,
    proxy: []const u8,
    index: i32,
    /// GEOIP/GEOSITE record count, -1 when not applicable.
    size: i32,
    has_extra: bool,
    disabled: bool,
    hit_count: u64,
    miss_count: u64,
    hit_at_unix_ms: ?i64,
    miss_at_unix_ms: ?i64,
};

fn convertRule(arena: std.mem.Allocator, raw: *const c.RuleInfo) Error!Rule {
    return .{
        .rule_type = try copy.string(arena, raw.rule_type),
        .payload = try copy.string(arena, raw.payload),
        .proxy = try copy.string(arena, raw.proxy),
        .index = raw.index,
        .size = raw.size,
        .has_extra = raw.has_extra != 0,
        .disabled = raw.disabled != 0,
        .hit_count = raw.hit_count,
        .miss_count = raw.miss_count,
        .hit_at_unix_ms = if (raw.hit_at_unix_ms == 0) null else raw.hit_at_unix_ms,
        .miss_at_unix_ms = if (raw.miss_at_unix_ms == 0) null else raw.miss_at_unix_ms,
    };
}

/// The routing table in evaluation order.
pub fn rules(allocator: std.mem.Allocator) Error!owned.Owned([]const Rule) {
    return owned.fetchList(c.RuleInfo, Rule, allocator, c.mihomo_get_rules, convertRule);
}

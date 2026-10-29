// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Error plumbing shared by every wrapper module.
//!
//! `lastError()` is thread-local: a failing call only overwrites the reason on
//! the thread that made it, and the reason stays valid until the next failing
//! call on that thread.

const std = @import("std");
const c = @import("c_api.zig");

/// Any failure reported by the core, plus allocation failures while copying
/// results. The human-readable reason is in `lastError()`.
pub const Error = error{ Mihomo, OutOfMemory };

const max_error_len = 1024;

threadlocal var err_buffer: [max_error_len]u8 = undefined;
threadlocal var err_len: usize = 0;

/// Reason for the most recent `Error.Mihomo` on this thread.
pub fn lastError() []const u8 {
    return err_buffer[0..err_len];
}

/// Consumes `err_ptr` (freeing it) and records it as this thread's last error.
pub fn captureErr(err_ptr: ?[*:0]u8) Error {
    const ptr = err_ptr orelse {
        err_len = 0;
        return Error.Mihomo;
    };
    defer c.mihomo_free(@ptrCast(ptr));
    const msg = std.mem.span(ptr);
    err_len = @min(msg.len, max_error_len);
    @memcpy(err_buffer[0..err_len], msg[0..err_len]);
    return Error.Mihomo;
}

pub fn checkStatus(status: c_int, err_ptr: ?[*:0]u8) Error!void {
    if (status == 0) return;
    return captureErr(err_ptr);
}

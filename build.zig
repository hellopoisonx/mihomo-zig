// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
const std = @import("std");

const version_option = "mihomo-version";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `go build -buildmode=c-shared` only produces a host library, so the whole
    // graph is pinned to natively built Linux x86_64.
    const resolved = target.result;
    if (resolved.os.tag != .linux or resolved.cpu.arch != .x86_64) {
        @panic("libmihomo targets native Linux x86_64 only; cross-compiling the Go library is out of scope");
    }

    const go_version = b.option([]const u8, version_option, "value for constant.Version baked into the Go library") orelse "zig-ffi-dev";
    const go_build_time = utcNowIso8601();

    // --- Go shared library ---------------------------------------------------
    const go = b.addSystemCommand(&.{"go"});
    go.setCwd(b.path("."));
    go.setEnvironmentVariable("CGO_ENABLED", "1");
    go.addArgs(&.{
        "build",
        "-buildmode=c-shared",
        "-tags",
        "with_gvisor",
        "-trimpath",
        "-ldflags",
        b.fmt(
            "-s -w -X github.com/metacubex/mihomo/constant.Version={s} -X github.com/metacubex/mihomo/constant.BuildTime={s}",
            .{ go_version, go_build_time },
        ),
    });
    // `go build` reads the whole module tree (ffi/ + the submodule), and Zig
    // cannot watch a directory as an input (`file_inputs` rejects dirs).
    // Declaring the step as side-effecting re-runs it every build, which costs
    // a warm `go build` (about a second) and can never serve a stale library;
    // the output hash still lets dependents stay cached.
    go.has_side_effects = true;
    go.addArg("-o");
    const shared_lib = go.addOutputFileArg("libmihomo.so");
    go.addArg("./ffi");

    const lib_step = b.step("lib", "Build libmihomo.so (Go c-shared)");
    lib_step.dependOn(&go.step);

    const install_lib = b.addInstallFileWithDir(shared_lib, .lib, "libmihomo.so");
    b.getInstallStep().dependOn(&install_lib.step);

    // --- Zig consumers -------------------------------------------------------
    // The project ships a library, not an executable: export src/mihomo.zig as a
    // canonical module so downstream Zig programs can import it via `b.addModule`.
    const lib_module = b.addModule("mihomo", .{
        .root_source_file = b.path("src/mihomo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkMihomo(lib_module, shared_lib);
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("mihomo", lib_module);
    // The layout test imports a translate-c view of ffi/mihomo_abi.h to prove
    // the hand-written extern structs match the C records field for field.
    // (Step.TranslateC is deprecated in 0.17 in favour of the packaged
    // translate-c, but it still ships and keeps the test offline.)
    const translate_abi = b.addTranslateC(.{
        .root_source_file = b.path("ffi/mihomo_abi.h"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("mihomo_abi", translate_abi.createModule());

    const e2e = b.addTest(.{ .name = "e2e", .root_module = test_module });
    e2e.step.dependOn(&go.step);

    const run_e2e = b.addRunArtifact(e2e);
    // The default test-runner protocol deadlocks against this graph (the child
    // blocks reading its protocol pipe while the maker waits on a futex), so
    // stream the test output directly instead.
    run_e2e.stdio = .inherit;
    run_e2e.step.dependOn(&go.step);

    const test_step = b.step("test", "Run the libmihomo end-to-end test");
    test_step.dependOn(&run_e2e.step);

    const test_build_step = b.step("test-build", "Compile the end-to-end test without running it");
    test_build_step.dependOn(&e2e.step);
}

fn linkMihomo(m: *std.Build.Module, shared_lib: std.Build.LazyPath) void {
    m.linkSystemLibrary("mihomo", .{});
    m.addLibraryPath(shared_lib.dirname());
    m.addRPath(shared_lib.dirname());
}

/// ISO-8601 UTC timestamp for `constant.BuildTime`, matching `date -u` output
/// closely enough for a version banner.
fn utcNowIso8601() []const u8 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return "unknown time";

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Static buffer: build.zig runs once and never frees.
    const buffer = struct {
        var bytes: [40]u8 = undefined;
    }.bytes[0..];

    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "unknown time";
}

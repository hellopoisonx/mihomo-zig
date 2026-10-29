// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Hand-written declarations for the `libmihomo` C ABI.
//!
//! Signatures and record layouts must stay in lockstep with `ffi/*.go` and
//! `ffi/mihomo_abi.h`: a drift in either direction is caught at link time
//! (missing symbol) or by the layout assertions in tests/e2e.zig, never
//! silently.

/// `mihomo log.LogLevel` (mihomo/log/level.go:17-23).
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    err = 3,
    silent = 4,
};

/// Fired on arbitrary Go scheduler threads; `payload` is only valid for the
/// duration of the call.
pub const LogCallback = *const fn (ctx: ?*anyopaque, level: u8, payload: [*:0]const u8) callconv(.c) void;

/// Fired once per second from a dedicated pump goroutine.
pub const TrafficCallback = *const fn (
    ctx: ?*anyopaque,
    up_now: u64,
    down_now: u64,
    up_total: u64,
    down_total: u64,
    memory: u64,
) callconv(.c) void;

// --- typed records (ffi/mihomo_abi.h) ---------------------------------------

/// One sample of a proxy's default test-URL delay history.
pub const DelaySample = extern struct {
    time_unix_ms: i64,
    delay_ms: u32,
};

/// One outbound proxy or proxy group. Every string pointer is non-null.
pub const ProxyInfo = extern struct {
    name: [*:0]const u8,
    kind: [*:0]const u8,
    now: [*:0]const u8,
    provider_name: [*:0]const u8,
    dialer_proxy: [*:0]const u8,
    interface_name: [*:0]const u8,
    icon: [*:0]const u8,
    empty_fallback: [*:0]const u8,
    history: ?[*]const DelaySample,
    members: ?[*]const [*:0]const u8,
    history_len: u32,
    members_len: u32,
    routing_mark: i32,
    delay_ms: i32,
    is_group: u8,
    udp: u8,
    xudp: u8,
    uot: u8,
    tfo: u8,
    mptcp: u8,
    smux: u8,
    alive: u8,
    hidden: u8,
};

/// One live connection (`statistic.TrackerInfo`).
pub const ConnectionInfo = extern struct {
    id: [*:0]const u8,
    network: [*:0]const u8,
    inbound_type: [*:0]const u8,
    source_ip: [*:0]const u8,
    destination_ip: [*:0]const u8,
    host: [*:0]const u8,
    inbound_name: [*:0]const u8,
    inbound_user: [*:0]const u8,
    dns_mode: [*:0]const u8,
    process: [*:0]const u8,
    process_path: [*:0]const u8,
    special_proxy: [*:0]const u8,
    special_rules: [*:0]const u8,
    sniff_host: [*:0]const u8,
    remote_destination: [*:0]const u8,
    rule: [*:0]const u8,
    rule_payload: [*:0]const u8,
    chains: ?[*]const [*:0]const u8,
    provider_chains: ?[*]const [*:0]const u8,
    upload: i64,
    download: i64,
    start_unix_ms: i64,
    uid: u32,
    chains_len: u32,
    provider_chains_len: u32,
    source_port: u16,
    destination_port: u16,
    inbound_port: u16,
    dscp: u8,
};

/// Connection table plus process-wide totals.
pub const ConnectionsSnapshot = extern struct {
    connections: ?[*]const ConnectionInfo,
    connections_len: u32,
    upload_total: i64,
    download_total: i64,
    memory: u64,
};

/// One routing rule.
pub const RuleInfo = extern struct {
    rule_type: [*:0]const u8,
    payload: [*:0]const u8,
    proxy: [*:0]const u8,
    index: i32,
    size: i32,
    hit_count: u64,
    miss_count: u64,
    hit_at_unix_ms: i64,
    miss_at_unix_ms: i64,
    disabled: u8,
    has_extra: u8,
};

/// One proxy provider.
pub const ProviderInfo = extern struct {
    name: [*:0]const u8,
    provider_type: [*:0]const u8,
    vehicle_type: [*:0]const u8,
    test_url: [*:0]const u8,
    updated_at_unix_ms: i64,
    proxy_count: u32,
};

/// One entry of a group latency sweep.
pub const DelayEntry = extern struct {
    name: [*:0]const u8,
    delay_ms: i32,
};

/// One DNS resource record.
pub const DnsRecord = extern struct {
    name: [*:0]const u8,
    data: [*:0]const u8,
    ttl: u32,
    record_type: u16,
};

/// Result of a DNS query through the core resolver.
pub const DnsResult = extern struct {
    answers: ?[*]const DnsRecord,
    authority: ?[*]const DnsRecord,
    additional: ?[*]const DnsRecord,
    answers_len: u32,
    authority_len: u32,
    additional_len: u32,
    status: i32,
    truncated: u8,
    recursion_desired: u8,
    recursion_available: u8,
    authenticated_data: u8,
    checking_disabled: u8,
};

// --- lifecycle ---------------------------------------------------------------

/// Static strings owned by the library. NEVER free these.
pub extern fn mihomo_version() [*:0]const u8;
pub extern fn mihomo_build_time() [*:0]const u8;

pub extern fn mihomo_start(
    home_dir: ?[*:0]const u8,
    config_yaml: [*:0]const u8,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_reload(config_yaml: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;
pub extern fn mihomo_stop(err_out: ?*?[*:0]u8) c_int;
pub extern fn mihomo_test_config(config_yaml: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;

pub extern fn mihomo_set_log_callback(cb: ?LogCallback, ctx: ?*anyopaque) void;
pub extern fn mihomo_set_traffic_callback(cb: ?TrafficCallback, ctx: ?*anyopaque) void;

// --- typed queries -----------------------------------------------------------
// Each `out` pointer owns one C allocation; release it with mihomo_free.

pub extern fn mihomo_get_proxies(
    out: ?*?[*]ProxyInfo,
    out_len: ?*u32,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_get_proxy(
    name: [*:0]const u8,
    out: ?*?*ProxyInfo,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_get_groups(
    out: ?*?[*]ProxyInfo,
    out_len: ?*u32,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_get_connections(
    out: ?*?*ConnectionsSnapshot,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_get_rules(
    out: ?*?[*]RuleInfo,
    out_len: ?*u32,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_get_providers(
    out: ?*?[*]ProviderInfo,
    out_len: ?*u32,
    err_out: ?*?[*:0]u8,
) c_int;

pub extern fn mihomo_url_test(
    name: [*:0]const u8,
    url: [*:0]const u8,
    timeout_ms: u32,
    expected: ?[*:0]const u8,
    delay_out: ?*i32,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_group_url_test(
    group: [*:0]const u8,
    url: [*:0]const u8,
    timeout_ms: u32,
    expected: ?[*:0]const u8,
    out: ?*?[*]DelayEntry,
    out_len: ?*u32,
    err_out: ?*?[*:0]u8,
) c_int;
pub extern fn mihomo_dns_query(
    name: [*:0]const u8,
    type_str: ?[*:0]const u8,
    out: ?*?*DnsResult,
    err_out: ?*?[*:0]u8,
) c_int;

// --- operations --------------------------------------------------------------

pub extern fn mihomo_close_connection(id: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;
pub extern fn mihomo_close_all_connections() void;
pub extern fn mihomo_update_provider(name: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;
pub extern fn mihomo_healthcheck_provider(name: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;
pub extern fn mihomo_select_proxy(group: [*:0]const u8, name: [*:0]const u8, err_out: ?*?[*:0]u8) c_int;

// --- JSON escape hatch -------------------------------------------------------
// Byte-identical to the upstream REST handlers (hub/route/*.go).

pub extern fn mihomo_get_proxies_json(err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_get_proxy_json(name: [*:0]const u8, err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_get_groups_json(err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_get_connections_json(err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_get_rules_json(err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_get_providers_json(err_out: ?*?[*:0]u8) ?[*:0]u8;
pub extern fn mihomo_url_test_json(
    name: [*:0]const u8,
    url: [*:0]const u8,
    timeout_ms: u32,
    expected: ?[*:0]const u8,
    err_out: ?*?[*:0]u8,
) ?[*:0]u8;
pub extern fn mihomo_group_url_test_json(
    group: [*:0]const u8,
    url: [*:0]const u8,
    timeout_ms: u32,
    expected: ?[*:0]const u8,
    err_out: ?*?[*:0]u8,
) ?[*:0]u8;
pub extern fn mihomo_dns_query_json(
    name: [*:0]const u8,
    type_str: ?[*:0]const u8,
    err_out: ?*?[*:0]u8,
) ?[*:0]u8;

/// Releases any pointer returned by this library. NULL is safe.
pub extern fn mihomo_free(ptr: ?*anyopaque) void;

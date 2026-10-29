// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
//! Idiomatic Zig wrapper over the `libmihomo` C ABI.
//!
//! This file is the module root: it re-exports the implementation split by
//! domain, so `@import("mihomo")` keeps one flat API.
//!
//! - `lifecycle.zig` — start/stop/reload, config validation, push callbacks.
//! - `proxy.zig` — proxy/group records, latency probes, selection.
//! - `connection.zig` — live connection snapshot and close operations.
//! - `rule.zig`, `provider.zig`, `dns.zig` — records and queries per domain.
//! - `json.zig` — lossless JSON escape hatch for fields the records omit.
//! - `owned.zig`, `error.zig`, `copy.zig` — arena ownership, per-thread error
//!   text, C-record copying.
//!
//! Ownership rules:
//!  * Typed queries copy every record out of the C allocation into one arena;
//!    `Owned(T).deinit()` releases everything it holds.
//!  * `lastError()` is per-thread and only valid until the next failing call on
//!    the same thread.
//!  * Callbacks may fire from Go scheduler threads; they must be thread-safe
//!    and must not call back into this module from the callback itself.

pub const c_api = @import("c_api.zig");

const lifecycle = @import("lifecycle.zig");
const proxy_mod = @import("proxy.zig");
const connection_mod = @import("connection.zig");
const rule_mod = @import("rule.zig");
const provider_mod = @import("provider.zig");
const dns_mod = @import("dns.zig");
const json_mod = @import("json.zig");
const owned = @import("owned.zig");
const errors = @import("error.zig");

pub const LogLevel = c_api.LogLevel;
pub const LogCallback = c_api.LogCallback;
pub const TrafficCallback = c_api.TrafficCallback;

/// Any failure reported by the core, plus allocation failures while copying
/// results. The human-readable reason is in `lastError()`.
pub const Error = errors.Error;

/// Reason for the most recent `Error.Mihomo` on this thread.
pub const lastError = errors.lastError;

/// A value plus the arena that owns every string and slice inside it.
/// Treat it as move-only: call `deinit()` exactly once.
pub const Owned = owned.Owned;

// --- lifecycle ---------------------------------------------------------------

pub const version = lifecycle.version;
pub const buildTime = lifecycle.buildTime;
pub const start = lifecycle.start;
pub const reload = lifecycle.reload;
pub const stop = lifecycle.stop;
pub const testConfig = lifecycle.testConfig;
pub const setLogCallback = lifecycle.setLogCallback;
pub const setTrafficCallback = lifecycle.setTrafficCallback;

// --- typed records -----------------------------------------------------------

pub const DelaySample = proxy_mod.DelaySample;
pub const Proxy = proxy_mod.Proxy;
pub const DelayEntry = proxy_mod.DelayEntry;
pub const Connection = connection_mod.Connection;
pub const Connections = connection_mod.Connections;
pub const Rule = rule_mod.Rule;
pub const Provider = provider_mod.Provider;
pub const DnsRecord = dns_mod.DnsRecord;
pub const DnsResult = dns_mod.DnsResult;

// --- typed queries -----------------------------------------------------------

pub const proxies = proxy_mod.proxies;
pub const proxy = proxy_mod.proxy;
pub const groups = proxy_mod.groups;
pub const connections = connection_mod.connections;
pub const rules = rule_mod.rules;
pub const providers = provider_mod.providers;
pub const urlTest = proxy_mod.urlTest;
pub const groupUrlTest = proxy_mod.groupUrlTest;
pub const dnsQuery = dns_mod.dnsQuery;

// --- operations --------------------------------------------------------------

pub const closeConnection = connection_mod.closeConnection;
pub const closeAllConnections = connection_mod.closeAllConnections;
pub const updateProvider = provider_mod.updateProvider;
pub const healthcheckProvider = provider_mod.healthcheckProvider;
pub const selectProxy = proxy_mod.selectProxy;

// --- JSON escape hatch -------------------------------------------------------

pub const getProxiesJson = json_mod.getProxiesJson;
pub const getProxyJson = json_mod.getProxyJson;
pub const getGroupsJson = json_mod.getGroupsJson;
pub const getConnectionsJson = json_mod.getConnectionsJson;
pub const getRulesJson = json_mod.getRulesJson;
pub const getProvidersJson = json_mod.getProvidersJson;
pub const urlTestJson = json_mod.urlTestJson;
pub const groupUrlTestJson = json_mod.groupUrlTestJson;
pub const dnsQueryJson = json_mod.dnsQueryJson;

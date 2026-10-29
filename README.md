# mihomo-zig

Embed [mihomo](https://github.com/MetaCubeX/mihomo) as a C ABI shared library
and drive it directly from Zig — no external controller, no REST round trips.

- `mihomo/` — upstream checkout, registered as a git submodule (branch `Meta`).
- `ffi/mihomo_abi.h` — C records shared with callers; single source of truth for layouts.
- `ffi/block.go` — one-allocation result blocks (records, nested arrays and strings).
- `ffi/exports_typed.go` — typed queries that fill the C records.
- `ffi/exports_query.go` — JSON escape hatch (same bytes as the REST handlers).
- `src/mihomo.zig` — module root; re-exports the wrappers below as one flat API.
- `src/c_api.zig` — hand-written `extern` records and declarations.
- `src/lifecycle.zig` — start/stop/reload, config validation, callbacks, version.
- `src/proxy.zig` — proxy/group records, queries, latency probes, selection.
- `src/connection.zig` — connection snapshot and close operations.
- `src/rule.zig`, `src/provider.zig`, `src/dns.zig` — records and queries per domain.
- `src/json.zig` — JSON escape hatch.
- `src/owned.zig`, `src/error.zig`, `src/copy.zig` — arena ownership, per-thread
  error text, C-record copying.
- `tests/e2e.zig` — boots the core, pushes real traffic through the mixed
  inbound, asserts on the typed records, and compares every C record against
  `src/c_api.zig` through translate-c.

The project builds a library only; it installs `zig-out/lib/libmihomo.so` and no
executable. `src/mihomo.zig` is the Zig module consumers import into their own
programs.

## Upstream changes: none

The submodule is pinned at `3f27ef39` and contains **zero source modifications**.
Everything needed (lifecycle, log/traffic streams, proxies, groups, connections,
rules, providers, DNS, latency tests) is already an exported Go API. The version
string is injected at link time, exactly like upstream's `Makefile`:

```
-ldflags "-X github.com/metacubex/mihomo/constant.Version=… -X github.com/metacubex/mihomo/constant.BuildTime=…"
```

## Build

Requirements: Linux x86_64, Zig 0.17.0, Go ≥ 1.21 (with cgo), gcc, network on
the first build (Go modules).

```sh
zig build                      # install zig-out/lib/libmihomo.so only
zig build -Dmihomo-version=$(git -C mihomo rev-parse --short HEAD)
zig build lib                  # build the Go shared library without installing
zig build test                 # end-to-end suite (starts a real core, ~2 s)
zig build test-build           # compile the suite without running it
```

`constant.BuildTime` is the UTC time of the last configure run (Zig caches the
generated configuration until `build.zig` or its options change), so it tracks
graph changes rather than every build.

`go build` reads the whole module tree (`ffi/` plus the submodule) and Zig cannot
watch a directory as a step input, so the Go step is declared side-effecting and
re-runs on every build. That costs a warm `go build` (about a second) and can
never hand back a stale library; the output hash still keeps dependent
compilations cached.

## Linking from Zig

```zig
const mihomo = @import("mihomo"); // module wired by build.zig

try mihomo.start(allocator, "/tmp/home", yaml_bytes);
defer mihomo.stop() catch {};

// `examples/mini.yaml` is a minimal config to start with.
var proxies = try mihomo.proxies(allocator);
defer proxies.deinit(); // one arena releases every string and slice
for (proxies.value) |p| {
    if (p.is_group) std.debug.print("{s}: now={s} members={d}\n", .{
        p.name, p.now, p.members.len,
    });
}
```

## Memory model

Every typed query builds **one C allocation** holding a record array, any nested
record/pointer arrays and all NUL-terminated strings. Pointers inside the result
point into that allocation, so callers release an entire result with a single
`mihomo_free(out)` — never free individual fields. This also applies to nested
arrays such as group members, connection chains and DNS sections.

The Zig wrapper copies each record into an arena and returns `mihomo.Owned(T)`;
`deinit()` releases everything. Treat `Owned` values as move-only and call
`deinit()` exactly once. The raw C API is usable directly from other languages:
include `ffi/mihomo_abi.h` (the cgo-generated `libmihomo.h` does it for you).

String convention: every `const char *` field is non-NULL and NUL-terminated;
fields that do not apply are empty strings. Arrays are `NULL` when their length
is `0`.

## Typed queries

| Symbol | Returns |
|---|---|
| `int32_t mihomo_get_proxies(mihomo_proxy_info **out, uint32_t *out_len, char **err_out)` | every proxy and group, sorted by name |
| `int32_t mihomo_get_proxy(const char *name, mihomo_proxy_info **out, char **err_out)` | one proxy (the out block holds a single record) |
| `int32_t mihomo_get_groups(mihomo_proxy_info **out, uint32_t *out_len, char **err_out)` | groups only, `members` filled |
| `int32_t mihomo_get_connections(mihomo_connections_snapshot **out, char **err_out)` | live connection table + totals |
| `int32_t mihomo_get_rules(mihomo_rule_info **out, uint32_t *out_len, char **err_out)` | routing table in evaluation order |
| `int32_t mihomo_get_providers(mihomo_provider_info **out, uint32_t *out_len, char **err_out)` | proxy providers, sorted by name |
| `int32_t mihomo_url_test(..., int32_t *delay_out, char **err_out)` | one delay in ms |
| `int32_t mihomo_group_url_test(..., mihomo_delay_entry **out, uint32_t *out_len, char **err_out)` | per-member delays; failures omitted |
| `int32_t mihomo_dns_query(const char *name, const char *type_str, mihomo_dns_result **out, char **err_out)` | answers/authority/additional records |

Records (defined in `ffi/mihomo_abi.h`):

| Record | Highlights |
|---|---|
| `mihomo_proxy_info` | `name`, `kind`, `now`, provider/dialer/interface, `delay_ms` (−1 unknown), recent latency `history`, `is_group` + `members`, udp/xudp/uot/tfo/mptcp/smux/alive/hidden |
| `mihomo_connection_info` | id, network, inbound type, src/dst ip+port, host, sniff host, dns mode, process, rule/payload, chains, provider chains, upload/download, start time |
| `mihomo_connections_snapshot` | totals, RSS, embedded connection array |
| `mihomo_rule_info` | type, payload, proxy, index, GEOIP/GEOSITE size, hit/miss statistics |
| `mihomo_provider_info` | name, provider type, vehicle type, test url, update time, proxy count |
| `mihomo_dns_result` | RCODE + flags, three record sections (`name`, `record_type`, `ttl`, `data`) |

`tests/e2e.zig` imports a translate-c view of the header and asserts size,
alignment, field count and every field offset against `src/c_api.zig`, so the two
layouts cannot drift silently.

## JSON escape hatch

The `*_json` exports mirror `hub/route/*.go` byte for byte and remain the
lossless path for fields the typed records do not model — provider subscription
info, per-URL delay histories, DNS question sections:

| Symbol | Notes |
|---|---|
| `char *mihomo_get_proxies_json(char **err_out)` | `{"proxies":{…}}` |
| `char *mihomo_get_proxy_json(const char *name, char **err_out)` | single proxy |
| `char *mihomo_get_groups_json(char **err_out)` | `{"proxies":[…]}`, groups only |
| `char *mihomo_get_connections_json(char **err_out)` | `statistic` snapshot |
| `char *mihomo_get_rules_json(char **err_out)` | includes `extra` stats and geo sizes |
| `char *mihomo_get_providers_json(char **err_out)` | provider objects self-serialize |
| `char *mihomo_url_test_json(..., char **err_out)` | `{"delay":n}`; `expected` = "200" / "200,204" / NULL |
| `char *mihomo_group_url_test_json(..., char **err_out)` | `{"proxy":delay,…}` |
| `char *mihomo_dns_query_json(const char *name, const char *type_str, char **err_out)` | same keys as `GET /dns/query` |

Zig wrappers: `getProxiesJson`, `getProxyJson`, `getGroupsJson`,
`getConnectionsJson`, `getRulesJson`, `getProvidersJson`, `urlTestJson`,
`groupUrlTestJson`, `dnsQueryJson`; each returns an allocator-owned `[]u8`.

## Lifecycle and operations

| Symbol | Notes |
|---|---|
| `const char *mihomo_version(void)` | static, do not free |
| `const char *mihomo_build_time(void)` | static, do not free |
| `int32_t mihomo_start(const char *home_dir, const char *config_yaml, char **err_out)` | once per process; `home_dir` may be NULL |
| `int32_t mihomo_reload(const char *config_yaml, char **err_out)` | same path as SIGHUP |
| `int32_t mihomo_stop(char **err_out)` | stops controller, listeners and pumps |
| `int32_t mihomo_test_config(const char *config_yaml, char **err_out)` | `mihomo -t` |
| `void mihomo_set_log_callback(mihomo_log_cb cb, void *ctx)` | levels 0..4 = debug..silent |
| `void mihomo_set_traffic_callback(mihomo_traffic_cb cb, void *ctx)` | 1 Hz: rates, totals, RSS |
| `int32_t mihomo_close_connection(const char *id, char **err_out)` | errors when the id is unknown |
| `void mihomo_close_all_connections(void)` | |
| `int32_t mihomo_update_provider(const char *name, char **err_out)` | |
| `int32_t mihomo_healthcheck_provider(const char *name, char **err_out)` | |
| `int32_t mihomo_select_proxy(const char *group, const char *name, char **err_out)` | persists the selection |
| `void mihomo_free(void *ptr)` | releases any result pointer; NULL-safe |

Callback signatures, as declared in the generated `libmihomo.h`:

```c
typedef void (*mihomo_log_cb)(void *ctx, uint8_t level, const char *payload);
typedef void (*mihomo_traffic_cb)(void *ctx, uint64_t up_now, uint64_t down_now,
                                  uint64_t up_total, uint64_t down_total, uint64_t memory);
```

Callbacks fire on Go scheduler threads and may run concurrently with each other
and with any `mihomo_*` call; they must be thread-safe, must not block for long,
and must not call `mihomo_stop` from inside the callback (teardown waits for the
pump goroutine).

## Known limits

- Linux x86_64 native only: the Go side is not cross-compiled.
- `mihomo_start` is deliberately not idempotent; restart = `stop` + `start`.
- `mihomo log` payloads are only valid for the duration of the callback.
- Group latency/delay data is keyed to mihomo's default test URL because
  `outboundgroup.ProxyGroup` does not expose the configured test URL; probe with
  `mihomo_url_test` when you need a specific URL.
- Provider subscription info and per-URL delay histories are JSON-only.

## License

Linking mihomo makes this project a derivative work of GPL-3.0 code; see
`LICENSE` (copied from the submodule). Note that upstream's README asks
downstream projects not affiliated with MetaCubeX to avoid the word `mihomo` in
their own project names, so rename before publishing.

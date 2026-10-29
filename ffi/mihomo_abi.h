/* SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
 *
 * Data structures shared by libmihomo.so and its callers.
 *
 * Ownership: every record returned by a mihomo_get_* function lives inside one
 * C allocation together with every string it references (directly or through a
 * nested array). Free the top-level pointer exactly once with mihomo_free();
 * no other pointer inside the result may be freed.
 *
 * String convention: every `const char *` field is non-NULL and NUL-terminated.
 * Fields that do not apply to a record are empty strings, never NULL.
 *
 * Layout mirrors src/c_api.zig field for field. tests/e2e.zig compares both
 * layouts with @cImport, so a drift breaks the test build.
 */
#ifndef MIHOMO_ABI_H
#define MIHOMO_ABI_H

#include <stdint.h>

/* One latency sample from a proxy's default test-URL history, oldest first. */
typedef struct mihomo_delay_sample {
	int64_t time_unix_ms;
	uint32_t delay_ms; /* 0 when that probe failed */
} mihomo_delay_sample;

/* One outbound proxy or proxy group (see tunnel.Proxies()). */
typedef struct mihomo_proxy_info {
	const char *name;
	const char *kind;            /* AdapterType, e.g. "Direct", "Selector" */
	const char *now;             /* selected member of a group, else "" */
	const char *provider_name;   /* "" when not served by a provider */
	const char *dialer_proxy;    /* "" when unset */
	const char *interface_name;  /* "" when unset */
	const char *icon;            /* group icon, "" when unset */
	const char *empty_fallback;  /* group empty-fallback name, "" when unset */
	const mihomo_delay_sample *history; /* recent samples, oldest first */
	const char *const *members;  /* group members, NULL when is_group == 0 */
	uint32_t history_len;
	uint32_t members_len;
	int32_t routing_mark;
	int32_t delay_ms;            /* last default-URL delay; -1 when unknown */
	uint8_t is_group;
	uint8_t udp;
	uint8_t xudp;
	uint8_t uot;
	uint8_t tfo;
	uint8_t mptcp;
	uint8_t smux;
	uint8_t alive;
	uint8_t hidden;
} mihomo_proxy_info;

/* One live connection (see statistic.TrackerInfo). */
typedef struct mihomo_connection_info {
	const char *id;
	const char *network;          /* "tcp" / "udp" */
	const char *inbound_type;     /* inbound listener type, e.g. "HTTP" */
	const char *source_ip;
	const char *destination_ip;
	const char *host;
	const char *inbound_name;
	const char *inbound_user;
	const char *dns_mode;
	const char *process;
	const char *process_path;
	const char *special_proxy;
	const char *special_rules;
	const char *sniff_host;
	const char *remote_destination;
	const char *rule;
	const char *rule_payload;
	const char *const *chains;
	const char *const *provider_chains;
	int64_t upload;
	int64_t download;
	int64_t start_unix_ms;
	uint32_t uid;
	uint32_t chains_len;
	uint32_t provider_chains_len;
	uint16_t source_port;
	uint16_t destination_port;
	uint16_t inbound_port;
	uint8_t dscp;
} mihomo_connection_info;

/* Snapshot of statistic.DefaultManager at the time of the call. */
typedef struct mihomo_connections_snapshot {
	const mihomo_connection_info *connections; /* NULL when connections_len == 0 */
	uint32_t connections_len;
	int64_t upload_total;
	int64_t download_total;
	uint64_t memory; /* RSS in bytes */
} mihomo_connections_snapshot;

/* One routing rule (see tunnel.Rules()). */
typedef struct mihomo_rule_info {
	const char *rule_type;
	const char *payload;
	const char *proxy;
	int32_t index;
	int32_t size;              /* GEOIP/GEOSITE record count, else -1 */
	uint64_t hit_count;
	uint64_t miss_count;
	int64_t hit_at_unix_ms;    /* 0 when never */
	int64_t miss_at_unix_ms;   /* 0 when never */
	uint8_t disabled;
	uint8_t has_extra;         /* hit/miss statistics are only valid when 1 */
} mihomo_rule_info;

/* One proxy provider (see tunnel.Providers()). */
typedef struct mihomo_provider_info {
	const char *name;
	const char *provider_type; /* "Proxy" / "Rule" */
	const char *vehicle_type;  /* "File" / "HTTP" / "Inline" / "Compatible" */
	const char *test_url;
	int64_t updated_at_unix_ms; /* 0 when the vehicle has no update time */
	uint32_t proxy_count;
} mihomo_provider_info;

/* One entry of a proxy-group latency sweep. */
typedef struct mihomo_delay_entry {
	const char *name;
	int32_t delay_ms;
} mihomo_delay_entry;

/* One DNS resource record (answer, authority and additional sections). */
typedef struct mihomo_dns_record {
	const char *name;
	const char *data; /* record text without the common header */
	uint32_t ttl;
	uint16_t record_type; /* dns.Type A/AAAA/... */
} mihomo_dns_record;

/* Result of a DNS query through the core resolver. */
typedef struct mihomo_dns_result {
	const mihomo_dns_record *answers;
	const mihomo_dns_record *authority;
	const mihomo_dns_record *additional;
	uint32_t answers_len;
	uint32_t authority_len;
	uint32_t additional_len;
	int32_t status; /* DNS RCODE */
	uint8_t truncated;
	uint8_t recursion_desired;
	uint8_t recursion_available;
	uint8_t authenticated_data;
	uint8_t checking_disabled;
} mihomo_dns_result;

#endif /* MIHOMO_ABI_H */

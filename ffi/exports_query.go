// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// JSON exports: the lossless escape hatch next to the typed records in
// exports_typed.go. Each mirrors the semantics of the corresponding REST
// handler (hub/route/*.go) so callers get byte-identical JSON to what the
// external controller would return.

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// toCJSON marshals v and hands ownership to the caller. On marshal failure it
// writes errOut and returns NULL.
func toCJSON(errOut **C.char, v any) *C.char {
	buf, err := json.Marshal(v)
	if err != nil {
		setErr(errOut, "marshal: "+err.Error())
		return nil
	}
	return C.CString(string(buf))
}

func goStringOrEmpty(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

// mihomo_get_proxies_json mirrors GET /proxies.
//
//export mihomo_get_proxies_json
func mihomo_get_proxies_json(errOut **C.char) *C.char {
	return toCJSON(errOut, map[string]any{"proxies": tunnel.Proxies()})
}

// mihomo_get_proxy_json mirrors GET /proxies/{name}.
//
//export mihomo_get_proxy_json
func mihomo_get_proxy_json(name *C.char, errOut **C.char) *C.char {
	proxyName := goStringOrEmpty(name)
	proxy, exist := tunnel.Proxies()[proxyName]
	if !exist {
		setErr(errOut, "proxy not found: "+proxyName)
		return nil
	}
	return toCJSON(errOut, proxy)
}

// mihomo_get_groups_json mirrors GET /group: only adapters that are proxy groups.
//
//export mihomo_get_groups_json
func mihomo_get_groups_json(errOut **C.char) *C.char {
	groups := make([]constant.Proxy, 0)
	for _, proxy := range tunnel.Proxies() {
		if isGroupProxy(proxy) {
			groups = append(groups, proxy)
		}
	}
	return toCJSON(errOut, map[string]any{"proxies": groups})
}

// mihomo_get_connections_json mirrors GET /connections (snapshot form).
//
//export mihomo_get_connections_json
func mihomo_get_connections_json(errOut **C.char) *C.char {
	return toCJSON(errOut, statistic.DefaultManager.Snapshot())
}

// mihomo_close_connection mirrors DELETE /connections/{id}, but reports a
// missing id instead of silently succeeding.
//
//export mihomo_close_connection
func mihomo_close_connection(id *C.char, errOut **C.char) C.int32_t {
	connID := goStringOrEmpty(id)
	c := statistic.DefaultManager.Get(connID)
	if c == nil {
		return failC(errOut, "connection not found: "+connID)
	}
	_ = c.Close()
	return 0
}

// mihomo_close_all_connections mirrors DELETE /connections.
//
//export mihomo_close_all_connections
func mihomo_close_all_connections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

type ruleExtraJSON struct {
	Disabled  bool      `json:"disabled"`
	HitCount  uint64    `json:"hitCount"`
	HitAt     time.Time `json:"hitAt"`
	MissCount uint64    `json:"missCount"`
	MissAt    time.Time `json:"missAt"`
}

type ruleJSON struct {
	Index   int            `json:"index"`
	Type    string         `json:"type"`
	Payload string         `json:"payload"`
	Proxy   string         `json:"proxy"`
	Size    int            `json:"size"`
	Extra   *ruleExtraJSON `json:"extra,omitempty"`
}

// mihomo_get_rules_json mirrors GET /rules, including RuleWrapper statistics
// and GEOIP/GEOSITE record sizes.
//
//export mihomo_get_rules_json
func mihomo_get_rules_json(errOut **C.char) *C.char {
	rules := ruleRows()
	out := make([]ruleJSON, 0, len(rules))
	for _, row := range rules {
		item := ruleJSON{
			Index:   int(row.index),
			Type:    row.ruleType,
			Payload: row.payload,
			Proxy:   row.proxy,
			Size:    int(row.size),
		}
		if row.hasExtra {
			item.Extra = &ruleExtraJSON{
				Disabled:  row.disabled,
				HitCount:  row.hitCount,
				HitAt:     unixMilliOrZero(row.hitAtMs),
				MissCount: row.missCount,
				MissAt:    unixMilliOrZero(row.missAtMs),
			}
		}
		out = append(out, item)
	}
	return toCJSON(errOut, map[string]any{"rules": out})
}

func unixMilliOrZero(ms int64) time.Time {
	if ms == 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms)
}

// mihomo_get_providers_json mirrors GET /providers/proxies, including fields
// the typed record does not model (subscription info).
//
//export mihomo_get_providers_json
func mihomo_get_providers_json(errOut **C.char) *C.char {
	return toCJSON(errOut, map[string]any{"providers": tunnel.Providers()})
}

// mihomo_update_provider mirrors PUT /providers/proxies/{name}.
//
//export mihomo_update_provider
func mihomo_update_provider(name *C.char, errOut **C.char) C.int32_t {
	providerName := goStringOrEmpty(name)
	provider, exist := tunnel.Providers()[providerName]
	if !exist {
		return failC(errOut, "provider not found: "+providerName)
	}
	if err := provider.Update(); err != nil {
		return failC(errOut, err.Error())
	}
	return 0
}

// mihomo_healthcheck_provider mirrors GET /providers/proxies/{name}/healthcheck.
//
//export mihomo_healthcheck_provider
func mihomo_healthcheck_provider(name *C.char, errOut **C.char) C.int32_t {
	providerName := goStringOrEmpty(name)
	provider, exist := tunnel.Providers()[providerName]
	if !exist {
		return failC(errOut, "provider not found: "+providerName)
	}
	provider.HealthCheck()
	return 0
}

// mihomo_select_proxy mirrors PUT /proxies/{name} (Selector/URLTest group).
//
//export mihomo_select_proxy
func mihomo_select_proxy(group *C.char, name *C.char, errOut **C.char) C.int32_t {
	groupName := goStringOrEmpty(group)
	proxyName := goStringOrEmpty(name)

	proxy, exist := tunnel.Proxies()[groupName]
	if !exist {
		return failC(errOut, "proxy not found: "+groupName)
	}
	selector, ok := proxy.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return failC(errOut, "Must be a Selector")
	}
	if err := selector.Set(proxyName); err != nil {
		return failC(errOut, "Selector update error: "+err.Error())
	}
	cachefile.Cache().SetSelected(proxy.Name(), proxyName)
	return 0
}

// mihomo_url_test_json mirrors GET /proxies/{name}/delay as {"delay":n}.
//
//export mihomo_url_test_json
func mihomo_url_test_json(name *C.char, url *C.char, timeoutMs C.uint32_t, expected *C.char, errOut **C.char) *C.char {
	delay, err := runURLTest(goStringOrEmpty(name), goStringOrEmpty(url), goStringOrEmpty(expected), uint32(timeoutMs))
	if err != nil {
		setErr(errOut, err.Error())
		return nil
	}
	return toCJSON(errOut, map[string]any{"delay": delay})
}

// mihomo_group_url_test_json mirrors GET /group/{name}/delay as
// {proxy: delay, ...}; failed members are omitted.
//
//export mihomo_group_url_test_json
func mihomo_group_url_test_json(group *C.char, url *C.char, timeoutMs C.uint32_t, expected *C.char, errOut **C.char) *C.char {
	delays, err := runGroupURLTest(goStringOrEmpty(group), goStringOrEmpty(url), goStringOrEmpty(expected), uint32(timeoutMs))
	if err != nil {
		setErr(errOut, err.Error())
		return nil
	}
	return toCJSON(errOut, delays)
}

// mihomo_dns_query_json mirrors GET /dns/query, returning the same key set.
//
//export mihomo_dns_query_json
func mihomo_dns_query_json(name *C.char, typeStr *C.char, errOut **C.char) *C.char {
	response, err := exchangeDNS(goStringOrEmpty(name), goStringOrEmpty(typeStr))
	if err != nil {
		setErr(errOut, err.Error())
		return nil
	}

	responseData := map[string]any{
		"Status":   response.Rcode,
		"Question": response.Question,
		"TC":       response.Truncated,
		"RD":       response.RecursionDesired,
		"RA":       response.RecursionAvailable,
		"AD":       response.AuthenticatedData,
		"CD":       response.CheckingDisabled,
	}
	if rows := dnsRecordRows(response.Answer); len(rows) > 0 {
		responseData["Answer"] = dnsRowsToJSON(rows)
	}
	if rows := dnsRecordRows(response.Ns); len(rows) > 0 {
		responseData["Authority"] = dnsRowsToJSON(rows)
	}
	if rows := dnsRecordRows(response.Extra); len(rows) > 0 {
		responseData["Additional"] = dnsRowsToJSON(rows)
	}
	return toCJSON(errOut, responseData)
}

func dnsRowsToJSON(rows []dnsRecordRow) []map[string]any {
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		out = append(out, map[string]any{
			"name": row.name,
			"type": row.kind,
			"TTL":  row.ttl,
			"data": row.data,
		})
	}
	return out
}

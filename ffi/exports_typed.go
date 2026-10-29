// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// Typed queries: the primary API surface for Zig consumers.
//
// Every function fills the C records declared in mihomo_abi.h instead of
// returning JSON. The whole result lives in one C allocation: strings and
// nested arrays point into it, and the caller releases everything by passing the
// out-pointer to mihomo_free once.
//
// *_json exports in exports_query.go remain the lossless escape hatch (same
// bytes as the upstream REST API) for fields the typed records do not model,
// such as provider subscription info or per-URL delay histories.

/*
#include <stdint.h>
#include <stdlib.h>
#include "mihomo_abi.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/netip"
	"sort"
	"strings"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"github.com/miekg/dns"
)

// --- proxies -----------------------------------------------------------------

type delaySampleRow struct {
	timeMs  int64
	delayMs uint32
}

type proxyRow struct {
	name          string
	kind          string
	now           string
	providerName  string
	dialerProxy   string
	interfaceName string
	icon          string
	emptyFallback string
	members       []string
	history       []delaySampleRow
	routingMark   int32
	delayMs       int32
	isGroup       bool
	udp           bool
	xudp          bool
	uot           bool
	tfo           bool
	mptcp         bool
	smux          bool
	alive         bool
	hidden        bool
}

func cBool(v bool) C.uint8_t {
	if v {
		return 1
	}
	return 0
}

// proxyToRow snapshots one proxy. The default test URL is the yardstick for
// alive/delay because ProxyGroup does not expose the group's configured URL.
func proxyToRow(proxy constant.Proxy) proxyRow {
	info := proxy.ProxyInfo()
	row := proxyRow{
		name:          proxy.Name(),
		kind:          proxy.Type().String(),
		providerName:  info.ProviderName,
		dialerProxy:   info.DialerProxy,
		interfaceName: info.Interface,
		routingMark:   int32(info.RoutingMark),
		delayMs:       -1,
		udp:           proxy.SupportUDP(),
		uot:           proxy.SupportUOT(),
		xudp:          info.XUDP,
		tfo:           info.TFO,
		mptcp:         info.MPTCP,
		smux:          info.SMUX,
	}

	if proxy.AliveForTestUrl(constant.DefaultTestURL) {
		row.alive = true
		if delay := proxy.LastDelayForTestUrl(constant.DefaultTestURL); delay != math.MaxUint16 {
			row.delayMs = int32(delay)
		}
	}
	for _, sample := range proxy.DelayHistory() {
		row.history = append(row.history, delaySampleRow{
			timeMs:  sample.Time.UnixMilli(),
			delayMs: uint32(sample.Delay),
		})
	}

	if group, ok := proxy.Adapter().(outboundgroup.ProxyGroup); ok {
		row.isGroup = true
		row.now = group.Now()
		row.icon = group.Icon()
		row.hidden = group.Hidden()
		for _, member := range group.Proxies() {
			row.members = append(row.members, member.Name())
		}
		if fallback, ok := proxy.Adapter().(interface{ EmptyFallback() constant.Proxy }); ok {
			if empty := fallback.EmptyFallback(); empty != nil {
				row.emptyFallback = empty.Name()
			}
		}
	}
	return row
}

func sortedProxyRows(keep func(constant.Proxy) bool) []proxyRow {
	proxies := tunnel.Proxies()
	rows := make([]proxyRow, 0, len(proxies))
	for _, proxy := range proxies {
		if keep != nil && !keep(proxy) {
			continue
		}
		rows = append(rows, proxyToRow(proxy))
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].name < rows[j].name })
	return rows
}

func isGroupProxy(proxy constant.Proxy) bool {
	_, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	return ok
}

func proxyBlock(rows []proxyRow) (*C.mihomo_proxy_info, error) {
	nested := 0
	for i := range rows {
		nested += len(rows[i].history) * int(unsafe.Sizeof(C.mihomo_delay_sample{}))
	}
	block, err := newBlock(len(rows), int(unsafe.Sizeof(C.mihomo_proxy_info{})), nested, rows)
	if err != nil {
		return nil, err
	}
	records := unsafe.Slice((*C.mihomo_proxy_info)(block.mem), len(rows))
	for i := range rows {
		fillProxyInfo(block, &records[i], &rows[i])
	}
	return (*C.mihomo_proxy_info)(block.mem), nil
}

func fillProxyInfo(block *cBlock, record *C.mihomo_proxy_info, row *proxyRow) {
	record.name = block.str(row.name)
	record.kind = block.str(row.kind)
	record.now = block.str(row.now)
	record.provider_name = block.str(row.providerName)
	record.dialer_proxy = block.str(row.dialerProxy)
	record.interface_name = block.str(row.interfaceName)
	record.icon = block.str(row.icon)
	record.empty_fallback = block.str(row.emptyFallback)
	record.routing_mark = C.int32_t(row.routingMark)
	record.delay_ms = C.int32_t(row.delayMs)
	record.is_group = cBool(row.isGroup)
	record.udp = cBool(row.udp)
	record.xudp = cBool(row.xudp)
	record.uot = cBool(row.uot)
	record.tfo = cBool(row.tfo)
	record.mptcp = cBool(row.mptcp)
	record.smux = cBool(row.smux)
	record.alive = cBool(row.alive)
	record.hidden = cBool(row.hidden)

	record.members = block.strArray(row.members)
	record.members_len = C.uint32_t(len(row.members))

	if len(row.history) > 0 {
		sampleSize := int(unsafe.Sizeof(C.mihomo_delay_sample{}))
		samples := unsafe.Slice(
			(*C.mihomo_delay_sample)(block.nestedRecords(len(row.history), sampleSize)),
			len(row.history),
		)
		for i := range row.history {
			samples[i].time_unix_ms = C.int64_t(row.history[i].timeMs)
			samples[i].delay_ms = C.uint32_t(row.history[i].delayMs)
		}
		record.history = (*C.mihomo_delay_sample)(unsafe.Pointer(&samples[0]))
		record.history_len = C.uint32_t(len(row.history))
	}
}

// mihomo_get_proxies returns every proxy and proxy group, sorted by name.
//
//export mihomo_get_proxies
func mihomo_get_proxies(out **C.mihomo_proxy_info, outLen *C.uint32_t, errOut **C.char) C.int32_t {
	if out == nil || outLen == nil {
		return failC(errOut, "out parameters must not be NULL")
	}
	rows := sortedProxyRows(nil)
	list, err := proxyBlock(rows)
	if err != nil {
		return failC(errOut, err.Error())
	}
	*out = list
	*outLen = C.uint32_t(len(rows))
	return 0
}

// mihomo_get_proxy returns one proxy by name.
//
//export mihomo_get_proxy
func mihomo_get_proxy(name *C.char, out **C.mihomo_proxy_info, errOut **C.char) C.int32_t {
	if out == nil {
		return failC(errOut, "out parameter must not be NULL")
	}
	proxyName := goStringOrEmpty(name)
	proxy, exist := tunnel.Proxies()[proxyName]
	if !exist {
		return failC(errOut, "proxy not found: "+proxyName)
	}
	list, err := proxyBlock([]proxyRow{proxyToRow(proxy)})
	if err != nil {
		return failC(errOut, err.Error())
	}
	*out = list
	return 0
}

// mihomo_get_groups returns proxy groups only, with members filled in.
//
//export mihomo_get_groups
func mihomo_get_groups(out **C.mihomo_proxy_info, outLen *C.uint32_t, errOut **C.char) C.int32_t {
	if out == nil || outLen == nil {
		return failC(errOut, "out parameters must not be NULL")
	}
	rows := sortedProxyRows(isGroupProxy)
	list, err := proxyBlock(rows)
	if err != nil {
		return failC(errOut, err.Error())
	}
	*out = list
	*outLen = C.uint32_t(len(rows))
	return 0
}

// --- connections -------------------------------------------------------------

type connectionRow struct {
	id              string
	network         string
	inboundType     string
	sourceIP        string
	destinationIP   string
	host            string
	inboundName     string
	inboundUser     string
	dnsMode         string
	process         string
	processPath     string
	specialProxy    string
	specialRules    string
	sniffHost       string
	remoteDst       string
	rule            string
	rulePayload     string
	chains          []string
	providerChains  []string
	upload          int64
	download        int64
	startUnixMs     int64
	uid             uint32
	sourcePort      uint16
	destinationPort uint16
	inboundPort     uint16
	dscp            uint8
}

func addrString(addr netip.Addr) string {
	if !addr.IsValid() {
		return ""
	}
	return addr.String()
}

func connectionToRow(info *statistic.TrackerInfo) connectionRow {
	row := connectionRow{
		id:             info.UUID.String(),
		chains:         []string(info.Chain),
		providerChains: []string(info.ProviderChain),
		upload:         info.UploadTotal.Load(),
		download:       info.DownloadTotal.Load(),
		rule:           info.Rule,
		rulePayload:    info.RulePayload,
	}
	if !info.Start.IsZero() {
		row.startUnixMs = info.Start.UnixMilli()
	}
	if meta := info.Metadata; meta != nil {
		row.network = meta.NetWork.String()
		row.inboundType = meta.Type.String()
		row.sourceIP = addrString(meta.SrcIP)
		row.destinationIP = addrString(meta.DstIP)
		row.host = meta.Host
		row.inboundName = meta.InName
		row.inboundUser = meta.InUser
		row.dnsMode = meta.DNSMode.String()
		row.process = meta.Process
		row.processPath = meta.ProcessPath
		row.specialProxy = meta.SpecialProxy
		row.specialRules = meta.SpecialRules
		row.sniffHost = meta.SniffHost
		row.remoteDst = meta.RemoteDst
		row.uid = meta.Uid
		row.sourcePort = meta.SrcPort
		row.destinationPort = meta.DstPort
		row.inboundPort = meta.InPort
		row.dscp = meta.DSCP
	}
	return row
}

func fillConnection(block *cBlock, record *C.mihomo_connection_info, row *connectionRow) {
	record.id = block.str(row.id)
	record.network = block.str(row.network)
	record.inbound_type = block.str(row.inboundType)
	record.source_ip = block.str(row.sourceIP)
	record.destination_ip = block.str(row.destinationIP)
	record.host = block.str(row.host)
	record.inbound_name = block.str(row.inboundName)
	record.inbound_user = block.str(row.inboundUser)
	record.dns_mode = block.str(row.dnsMode)
	record.process = block.str(row.process)
	record.process_path = block.str(row.processPath)
	record.special_proxy = block.str(row.specialProxy)
	record.special_rules = block.str(row.specialRules)
	record.sniff_host = block.str(row.sniffHost)
	record.remote_destination = block.str(row.remoteDst)
	record.rule = block.str(row.rule)
	record.rule_payload = block.str(row.rulePayload)
	record.chains = block.strArray(row.chains)
	record.chains_len = C.uint32_t(len(row.chains))
	record.provider_chains = block.strArray(row.providerChains)
	record.provider_chains_len = C.uint32_t(len(row.providerChains))
	record.upload = C.int64_t(row.upload)
	record.download = C.int64_t(row.download)
	record.start_unix_ms = C.int64_t(row.startUnixMs)
	record.uid = C.uint32_t(row.uid)
	record.source_port = C.uint16_t(row.sourcePort)
	record.destination_port = C.uint16_t(row.destinationPort)
	record.inbound_port = C.uint16_t(row.inboundPort)
	record.dscp = C.uint8_t(row.dscp)
}

// mihomo_get_connections returns the live connection table plus global totals.
//
//export mihomo_get_connections
func mihomo_get_connections(out **C.mihomo_connections_snapshot, errOut **C.char) C.int32_t {
	if out == nil {
		return failC(errOut, "out parameter must not be NULL")
	}
	snapshot := statistic.DefaultManager.Snapshot()
	rows := make([]connectionRow, 0, len(snapshot.Connections))
	for _, connection := range snapshot.Connections {
		if connection == nil {
			continue
		}
		rows = append(rows, connectionToRow(connection))
	}

	connectionSize := int(unsafe.Sizeof(C.mihomo_connection_info{}))
	block, err := newBlock(1, int(unsafe.Sizeof(C.mihomo_connections_snapshot{})), len(rows)*connectionSize, rows)
	if err != nil {
		return failC(errOut, err.Error())
	}

	result := (*C.mihomo_connections_snapshot)(block.mem)
	result.upload_total = C.int64_t(snapshot.UploadTotal)
	result.download_total = C.int64_t(snapshot.DownloadTotal)
	result.memory = C.uint64_t(snapshot.Memory)
	result.connections_len = C.uint32_t(len(rows))
	if len(rows) > 0 {
		records := unsafe.Slice(
			(*C.mihomo_connection_info)(block.nestedRecords(len(rows), connectionSize)),
			len(rows),
		)
		for i := range rows {
			fillConnection(block, &records[i], &rows[i])
		}
		result.connections = (*C.mihomo_connection_info)(unsafe.Pointer(&records[0]))
	}

	*out = result
	return 0
}

// --- rules -------------------------------------------------------------------

type ruleRow struct {
	ruleType  string
	payload   string
	proxy     string
	index     int32
	size      int32
	hitCount  uint64
	missCount uint64
	hitAtMs   int64
	missAtMs  int64
	disabled  bool
	hasExtra  bool
}

func ruleRows() []ruleRow {
	rawRules := tunnel.Rules()
	rows := make([]ruleRow, 0, len(rawRules))
	for index, rule := range rawRules {
		row := ruleRow{
			ruleType: rule.RuleType().String(),
			payload:  rule.Payload(),
			proxy:    rule.Adapter(),
			index:    int32(index),
			size:     -1,
		}
		if wrapper, ok := rule.(constant.RuleWrapper); ok {
			row.hasExtra = true
			row.disabled = wrapper.IsDisabled()
			row.hitCount = wrapper.HitCount()
			row.missCount = wrapper.MissCount()
			if !wrapper.HitAt().IsZero() {
				row.hitAtMs = wrapper.HitAt().UnixMilli()
			}
			if !wrapper.MissAt().IsZero() {
				row.missAtMs = wrapper.MissAt().UnixMilli()
			}
			rule = wrapper.Unwrap()
		}
		if rule.RuleType() == constant.GEOIP || rule.RuleType() == constant.GEOSITE {
			row.size = int32(rule.(constant.RuleGroup).GetRecodeSize())
		}
		rows = append(rows, row)
	}
	return rows
}

// mihomo_get_rules returns the routing table in evaluation order.
//
//export mihomo_get_rules
func mihomo_get_rules(out **C.mihomo_rule_info, outLen *C.uint32_t, errOut **C.char) C.int32_t {
	if out == nil || outLen == nil {
		return failC(errOut, "out parameters must not be NULL")
	}
	rows := ruleRows()
	block, err := newBlock(len(rows), int(unsafe.Sizeof(C.mihomo_rule_info{})), 0, rows)
	if err != nil {
		return failC(errOut, err.Error())
	}
	records := unsafe.Slice((*C.mihomo_rule_info)(block.mem), len(rows))
	for i := range rows {
		record := &records[i]
		record.rule_type = block.str(rows[i].ruleType)
		record.payload = block.str(rows[i].payload)
		record.proxy = block.str(rows[i].proxy)
		record.index = C.int32_t(rows[i].index)
		record.size = C.int32_t(rows[i].size)
		record.hit_count = C.uint64_t(rows[i].hitCount)
		record.miss_count = C.uint64_t(rows[i].missCount)
		record.hit_at_unix_ms = C.int64_t(rows[i].hitAtMs)
		record.miss_at_unix_ms = C.int64_t(rows[i].missAtMs)
		record.disabled = cBool(rows[i].disabled)
		record.has_extra = cBool(rows[i].hasExtra)
	}
	*out = (*C.mihomo_rule_info)(block.mem)
	*outLen = C.uint32_t(len(rows))
	return 0
}

// --- providers ---------------------------------------------------------------

type providerRow struct {
	name         string
	providerType string
	vehicleType  string
	testURL      string
	updatedAtMs  int64
	proxyCount   uint32
}

// mihomo_get_providers returns the proxy providers, sorted by name.
//
//export mihomo_get_providers
func mihomo_get_providers(out **C.mihomo_provider_info, outLen *C.uint32_t, errOut **C.char) C.int32_t {
	if out == nil || outLen == nil {
		return failC(errOut, "out parameters must not be NULL")
	}
	providers := tunnel.Providers()
	rows := make([]providerRow, 0, len(providers))
	for _, provider := range providers {
		row := providerRow{
			name:         provider.Name(),
			providerType: provider.Type().String(),
			vehicleType:  provider.VehicleType().String(),
			testURL:      provider.HealthCheckURL(),
			proxyCount:   uint32(provider.Count()),
		}
		if updated, ok := provider.(interface{ UpdatedAt() time.Time }); ok {
			if at := updated.UpdatedAt(); !at.IsZero() {
				row.updatedAtMs = at.UnixMilli()
			}
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].name < rows[j].name })

	block, err := newBlock(len(rows), int(unsafe.Sizeof(C.mihomo_provider_info{})), 0, rows)
	if err != nil {
		return failC(errOut, err.Error())
	}
	records := unsafe.Slice((*C.mihomo_provider_info)(block.mem), len(rows))
	for i := range rows {
		record := &records[i]
		record.name = block.str(rows[i].name)
		record.provider_type = block.str(rows[i].providerType)
		record.vehicle_type = block.str(rows[i].vehicleType)
		record.test_url = block.str(rows[i].testURL)
		record.updated_at_unix_ms = C.int64_t(rows[i].updatedAtMs)
		record.proxy_count = C.uint32_t(rows[i].proxyCount)
	}
	*out = (*C.mihomo_provider_info)(block.mem)
	*outLen = C.uint32_t(len(rows))
	return 0
}

// --- latency probes ----------------------------------------------------------

// runURLTest probes one proxy with the same semantics as GET
// /proxies/{name}/delay.
func runURLTest(proxyName, testURL, expected string, timeoutMs uint32) (uint16, error) {
	if testURL == "" {
		return 0, errors.New("test url must not be empty")
	}
	expectedStatus, err := utils.NewUnsignedRanges[uint16](expected)
	if err != nil {
		return 0, fmt.Errorf("invalid expected status: %w", err)
	}
	proxy, exist := tunnel.Proxies()[proxyName]
	if !exist {
		return 0, fmt.Errorf("proxy not found: %s", proxyName)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	delay, err := proxy.URLTest(ctx, testURL, expectedStatus)
	if ctx.Err() != nil {
		return 0, errors.New("timeout")
	}
	if err != nil {
		return 0, err
	}
	if delay == 0 {
		return 0, errors.New("An error occurred in the delay test")
	}
	return delay, nil
}

// mihomo_url_test probes one proxy and writes its delay in milliseconds.
//
//export mihomo_url_test
func mihomo_url_test(name *C.char, url *C.char, timeoutMs C.uint32_t, expected *C.char, delayOut *C.int32_t, errOut **C.char) C.int32_t {
	if delayOut == nil {
		return failC(errOut, "delay_out must not be NULL")
	}
	delay, err := runURLTest(goStringOrEmpty(name), goStringOrEmpty(url), goStringOrEmpty(expected), uint32(timeoutMs))
	if err != nil {
		return failC(errOut, err.Error())
	}
	*delayOut = C.int32_t(delay)
	return 0
}

// runGroupURLTest probes every member of a proxy group, mirroring GET
// /group/{name}/delay including the "unfix a non-Selector group" side effect.
func runGroupURLTest(groupName, testURL, expected string, timeoutMs uint32) (map[string]uint16, error) {
	if testURL == "" {
		return nil, errors.New("test url must not be empty")
	}
	proxy, exist := tunnel.Proxies()[groupName]
	if !exist {
		return nil, fmt.Errorf("proxy not found: %s", groupName)
	}
	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return nil, fmt.Errorf("not a proxy group: %s", groupName)
	}
	if selectable, ok := proxy.Adapter().(outboundgroup.SelectAble); ok && proxy.Type() != constant.Selector {
		selectable.ForceSet("")
		cachefile.Cache().SetSelected(proxy.Name(), "")
	}
	expectedStatus, err := utils.NewUnsignedRanges[uint16](expected)
	if err != nil {
		return nil, fmt.Errorf("invalid expected status: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	return group.URLTest(ctx, testURL, expectedStatus)
}

type delayEntryRow struct {
	name    string
	delayMs int32
}

// mihomo_group_url_test probes every member of a group; failures are omitted,
// exactly like the upstream handler.
//
//export mihomo_group_url_test
func mihomo_group_url_test(group *C.char, url *C.char, timeoutMs C.uint32_t, expected *C.char, out **C.mihomo_delay_entry, outLen *C.uint32_t, errOut **C.char) C.int32_t {
	if out == nil || outLen == nil {
		return failC(errOut, "out parameters must not be NULL")
	}
	delays, err := runGroupURLTest(goStringOrEmpty(group), goStringOrEmpty(url), goStringOrEmpty(expected), uint32(timeoutMs))
	if err != nil {
		return failC(errOut, err.Error())
	}
	rows := make([]delayEntryRow, 0, len(delays))
	for name, delay := range delays {
		rows = append(rows, delayEntryRow{name: name, delayMs: int32(delay)})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].name < rows[j].name })

	block, err := newBlock(len(rows), int(unsafe.Sizeof(C.mihomo_delay_entry{})), 0, rows)
	if err != nil {
		return failC(errOut, err.Error())
	}
	records := unsafe.Slice((*C.mihomo_delay_entry)(block.mem), len(rows))
	for i := range rows {
		records[i].name = block.str(rows[i].name)
		records[i].delay_ms = C.int32_t(rows[i].delayMs)
	}
	*out = (*C.mihomo_delay_entry)(block.mem)
	*outLen = C.uint32_t(len(rows))
	return 0
}

// --- DNS ---------------------------------------------------------------------

type dnsRecordRow struct {
	name string
	data string
	ttl  uint32
	kind uint16
}

func dnsRecordRows(records []dns.RR) []dnsRecordRow {
	rows := make([]dnsRecordRow, 0, len(records))
	for _, record := range records {
		header := record.Header()
		rows = append(rows, dnsRecordRow{
			name: header.Name,
			data: strings.TrimPrefix(record.String(), header.String()),
			ttl:  header.Ttl,
			kind: header.Rrtype,
		})
	}
	return rows
}

// exchangeDNS resolves name through the core resolver and returns the raw
// message, shared by the typed and JSON exports.
func exchangeDNS(name, typeStr string) (*dns.Msg, error) {
	if resolver.DefaultResolver == nil {
		return nil, errors.New("DNS section is disabled")
	}
	qTypeStr := typeStr
	if qTypeStr == "" {
		qTypeStr = "A"
	}
	qType, exist := dns.StringToType[qTypeStr]
	if !exist {
		return nil, errors.New("invalid query type")
	}

	ctx, cancel := context.WithTimeout(context.Background(), resolver.DefaultDNSTimeout)
	defer cancel()

	message := dns.Msg{}
	message.SetQuestion(dns.Fqdn(name), qType)
	return resolver.DefaultResolver.ExchangeContext(ctx, &message)
}

type dnsResultRow struct {
	answers    []dnsRecordRow
	authority  []dnsRecordRow
	additional []dnsRecordRow
	status     int32
	truncated  bool
	rd         bool
	ra         bool
	ad         bool
	cd         bool
}

func fillDnsSection(block *cBlock, rows []dnsRecordRow) (*C.mihomo_dns_record, C.uint32_t) {
	if len(rows) == 0 {
		return nil, 0
	}
	recordSize := int(unsafe.Sizeof(C.mihomo_dns_record{}))
	records := unsafe.Slice(
		(*C.mihomo_dns_record)(block.nestedRecords(len(rows), recordSize)),
		len(rows),
	)
	for i := range rows {
		records[i].name = block.str(rows[i].name)
		records[i].data = block.str(rows[i].data)
		records[i].ttl = C.uint32_t(rows[i].ttl)
		records[i].record_type = C.uint16_t(rows[i].kind)
	}
	return (*C.mihomo_dns_record)(unsafe.Pointer(&records[0])), C.uint32_t(len(rows))
}

// mihomo_dns_query resolves a name through the core resolver.
//
//export mihomo_dns_query
func mihomo_dns_query(name *C.char, typeStr *C.char, out **C.mihomo_dns_result, errOut **C.char) C.int32_t {
	if out == nil {
		return failC(errOut, "out parameter must not be NULL")
	}
	response, err := exchangeDNS(goStringOrEmpty(name), goStringOrEmpty(typeStr))
	if err != nil {
		return failC(errOut, err.Error())
	}
	row := dnsResultRow{
		answers:    dnsRecordRows(response.Answer),
		authority:  dnsRecordRows(response.Ns),
		additional: dnsRecordRows(response.Extra),
		status:     int32(response.Rcode),
		truncated:  response.Truncated,
		rd:         response.RecursionDesired,
		ra:         response.RecursionAvailable,
		ad:         response.AuthenticatedData,
		cd:         response.CheckingDisabled,
	}
	nested := (len(row.answers) + len(row.authority) + len(row.additional)) * int(unsafe.Sizeof(C.mihomo_dns_record{}))
	block, err := newBlock(1, int(unsafe.Sizeof(C.mihomo_dns_result{})), nested, row)
	if err != nil {
		return failC(errOut, err.Error())
	}
	result := (*C.mihomo_dns_result)(block.mem)
	result.answers, result.answers_len = fillDnsSection(block, row.answers)
	result.authority, result.authority_len = fillDnsSection(block, row.authority)
	result.additional, result.additional_len = fillDnsSection(block, row.additional)
	result.status = C.int32_t(row.status)
	result.truncated = cBool(row.truncated)
	result.recursion_desired = cBool(row.rd)
	result.recursion_available = cBool(row.ra)
	result.authenticated_data = cBool(row.ad)
	result.checking_disabled = cBool(row.cd)
	*out = result
	return 0
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// Symbols 7-8: log and traffic push channels.
//
// Both pumps are started/stopped independently of the core lifecycle, but
// mihomo_stop also drains them (stopCallbackPumps) so that no Zig code is ever
// invoked after the library has been torn down.
//
// Threading contract for callers: pumps run on Go scheduler threads and may
// fire concurrently with each other and with any mihomo_* call. Callbacks must
// be thread-safe and must not call back into the library from the same
// goroutine that the pump is blocking on.

/*
#include <stdint.h>
#include <stdlib.h>

typedef void (*mihomo_log_cb)(void *ctx, uint8_t level, const char *payload);
typedef void (*mihomo_traffic_cb)(void *ctx, uint64_t up_now, uint64_t down_now,
                                  uint64_t up_total, uint64_t down_total, uint64_t memory);

// cgo cannot invoke a C function pointer value directly, so trampoline through
// static inline wrappers generated into the cgo preamble.
static inline void mihomo_invoke_log_cb(mihomo_log_cb cb, void *ctx, uint8_t level, const char *payload) {
	cb(ctx, level, payload);
}

static inline void mihomo_invoke_traffic_cb(mihomo_traffic_cb cb, void *ctx,
		uint64_t up_now, uint64_t down_now, uint64_t up_total, uint64_t down_total, uint64_t memory) {
	cb(ctx, up_now, down_now, up_total, down_total, memory);
}
*/
import "C"

import (
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type logPump struct {
	cb   C.mihomo_log_cb
	ctx  unsafe.Pointer
	sub  observable.Subscription[log.Event]
	done chan struct{}
}

type trafficPump struct {
	cb   C.mihomo_traffic_cb
	ctx  unsafe.Pointer
	stop chan struct{}
	done chan struct{}
}

var pumps struct {
	mu      sync.Mutex
	log     *logPump
	traffic *trafficPump
}

// mihomo_set_log_callback registers (or, with cb == NULL, unregisters) a log
// sink. level follows mihomo log.LogLevel: 0=debug 1=info 2=warning 3=error
// 4=silent (log/level.go:17-23). payload is valid only for the call duration.
//
//export mihomo_set_log_callback
func mihomo_set_log_callback(cb C.mihomo_log_cb, ctx unsafe.Pointer) {
	pumps.mu.Lock()
	defer pumps.mu.Unlock()

	stopLogLocked()

	if cb == nil {
		return
	}

	p := &logPump{cb: cb, ctx: ctx, sub: log.Subscribe(), done: make(chan struct{})}
	pumps.log = p

	go func(p *logPump) {
		defer close(p.done)
		// UnSubscribe closes the subscription channel, ending this range.
		for event := range p.sub {
			payload := C.CString(event.Payload)
			C.mihomo_invoke_log_cb(p.cb, p.ctx, C.uint8_t(event.LogLevel), payload)
			C.free(unsafe.Pointer(payload))
		}
	}(p)
}

// stopLogLocked unsubscribes and waits for the pump goroutine to finish, so no
// callback can fire once the unregister call returns.
func stopLogLocked() {
	p := pumps.log
	if p == nil {
		return
	}
	pumps.log = nil
	log.UnSubscribe(p.sub)
	<-p.done
}

// mihomo_set_traffic_callback registers (or, with cb == NULL, unregisters) a
// 1 Hz traffic heartbeat: per-second rates, cumulative totals and RSS.
//
//export mihomo_set_traffic_callback
func mihomo_set_traffic_callback(cb C.mihomo_traffic_cb, ctx unsafe.Pointer) {
	pumps.mu.Lock()
	defer pumps.mu.Unlock()

	stopTrafficLocked()

	if cb == nil {
		return
	}

	p := &trafficPump{cb: cb, ctx: ctx, stop: make(chan struct{}), done: make(chan struct{})}
	pumps.traffic = p

	go func(p *trafficPump) {
		defer close(p.done)

		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-p.stop:
				return
			case <-ticker.C:
				upNow, downNow := statistic.DefaultManager.Now()
				upTotal, downTotal := statistic.DefaultManager.Total()
				C.mihomo_invoke_traffic_cb(p.cb, p.ctx,
					C.uint64_t(upNow), C.uint64_t(downNow),
					C.uint64_t(upTotal), C.uint64_t(downTotal),
					C.uint64_t(statistic.DefaultManager.Memory()))
			}
		}
	}(p)
}

func stopTrafficLocked() {
	p := pumps.traffic
	if p == nil {
		return
	}
	pumps.traffic = nil
	close(p.stop)
	<-p.done
}

// stopCallbackPumps drains both pumps. Safe to call when nothing is registered.
func stopCallbackPumps() {
	pumps.mu.Lock()
	defer pumps.mu.Unlock()

	if pumps.log != nil {
		log.UnSubscribe(pumps.log.sub)
		pumps.log = nil
	}
	stopTrafficLocked()
}

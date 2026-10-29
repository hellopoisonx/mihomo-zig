// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// Runtime guards copied verbatim from mihomo main.go:82-99 (Meta branch,
// commit 3f27ef39). They must run exactly once, before any mihomo API is
// reachable, and they are why this file must not import "C": cgo init
// ordering would otherwise let the Go runtime touch net.DefaultResolver first.

import (
	"context"
	"fmt"
	"net"
	"os"
	"runtime"
	"sync"

	"go.uber.org/automaxprocs/maxprocs"
)

func main() {}

// runtimeOnce guards the one-time process-wide setup below.
var runtimeOnce sync.Once

func initRuntime() {
	runtimeOnce.Do(func() {
		// Defensive programming: panic when code mistakenly calls net.DefaultResolver
		net.DefaultResolver.PreferGo = true
		net.DefaultResolver.Dial = func(ctx context.Context, network, address string) (net.Conn, error) {
			//panic("should never be called")
			buf := make([]byte, 1024)
			for {
				n := runtime.Stack(buf, true)
				if n < len(buf) {
					buf = buf[:n]
					break
				}
				buf = make([]byte, 2*len(buf))
			}
			fmt.Fprintf(os.Stderr, "panic: should never be called\n\n%s", buf) // always print all goroutine stack
			os.Exit(2)
			return nil, nil
		}

		_, _ = maxprocs.Set(maxprocs.Logger(func(string, ...any) {}))
	})
}

// Process-wide core state shared by every export file.
var (
	stateMu sync.Mutex
	started bool
)

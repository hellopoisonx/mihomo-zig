// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// Symbols 1-6 and 23: process lifecycle and memory ownership.

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"path/filepath"
	"unsafe"

	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	listenerConfig "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
)

// Static strings owned by the library: callers must NOT free them.
var (
	cVersion   = C.CString(constant.Version)
	cBuildTime = C.CString(constant.BuildTime)
)

// setErr writes msg into *errOut when errOut is non-NULL. The caller owns the
// resulting string and releases it with mihomo_free.
func setErr(errOut **C.char, msg string) {
	if errOut == nil {
		return
	}
	*errOut = C.CString(msg)
}

func failC(errOut **C.char, msg string) C.int32_t {
	setErr(errOut, msg)
	return 1
}

// mihomo_version returns constant.Version as injected at link time.
//
//export mihomo_version
func mihomo_version() *C.char {
	return cVersion
}

// mihomo_build_time returns constant.BuildTime as injected at link time.
//
//export mihomo_build_time
func mihomo_build_time() *C.char {
	return cBuildTime
}

// mihomo_start boots the mihomo core once. home_dir may be NULL, in which case
// the current constant.Path home directory is kept.
//
//export mihomo_start
func mihomo_start(homeDir *C.char, configYaml *C.char, errOut **C.char) C.int32_t {
	initRuntime()

	if configYaml == nil || *configYaml == 0 {
		return failC(errOut, "config_yaml must be a non-empty YAML document")
	}
	yaml := []byte(C.GoString(configYaml))

	stateMu.Lock()
	defer stateMu.Unlock()

	if started {
		return failC(errOut, "already started")
	}

	if homeDir != nil && *homeDir != 0 {
		abs, err := filepath.Abs(C.GoString(homeDir))
		if err != nil {
			return failC(errOut, "resolve home_dir: "+err.Error())
		}
		constant.SetHomeDir(abs)
		constant.SetConfig(filepath.Join(abs, "config.yaml"))
		if err := config.Init(abs); err != nil {
			return failC(errOut, "init home_dir: "+err.Error())
		}
	}

	if err := hub.Parse(yaml); err != nil {
		return failC(errOut, "parse config: "+err.Error())
	}

	if updater.GeoAutoUpdate() {
		updater.RegisterGeoUpdater()
	}

	started = true
	return 0
}

// mihomo_reload re-applies a full configuration document to a started core,
// equivalent to the SIGHUP path in mihomo main.go:248.
//
//export mihomo_reload
func mihomo_reload(configYaml *C.char, errOut **C.char) C.int32_t {
	if configYaml == nil || *configYaml == 0 {
		return failC(errOut, "config_yaml must be a non-empty YAML document")
	}
	yaml := []byte(C.GoString(configYaml))

	stateMu.Lock()
	defer stateMu.Unlock()

	if !started {
		return failC(errOut, "not started")
	}

	if err := hub.Parse(yaml); err != nil {
		return failC(errOut, "parse config: "+err.Error())
	}
	return 0
}

// mihomo_stop tears down the external controller, every listener and both
// callback pumps. A later mihomo_start is allowed.
//
//export mihomo_stop
func mihomo_stop(errOut **C.char) C.int32_t {
	stateMu.Lock()
	defer stateMu.Unlock()

	if !started {
		return failC(errOut, "not started")
	}

	// An empty route.Config makes start() close the previous controller
	// without listening again (hub/route/server.go:162-166).
	route.ReCreateServer(&route.Config{})

	// executor.Shutdown only tears down TUN: upstream never closes the port
	// listeners because the process exits right after. Re-create every one of
	// them disabled (port 0 / empty config), the same path a config reload
	// takes (hub/executor/executor.go:186-208), so sockets are released and the
	// process can keep running.
	listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	listener.ReCreateTuic(listenerConfig.TuicServer{}, tunnel.Tunnel)

	executor.Shutdown()
	stopCallbackPumps()
	started = false
	return 0
}

// mihomo_test_config validates a configuration document without applying it,
// equivalent to `mihomo -t`.
//
//export mihomo_test_config
func mihomo_test_config(configYaml *C.char, errOut **C.char) C.int32_t {
	initRuntime()

	if configYaml == nil || *configYaml == 0 {
		return failC(errOut, "config_yaml must be a non-empty YAML document")
	}

	if _, err := executor.ParseWithBytes([]byte(C.GoString(configYaml))); err != nil {
		return failC(errOut, err.Error())
	}
	return 0
}

// mihomo_free releases any pointer handed out by this library. NULL is safe.
// The static strings from mihomo_version/mihomo_build_time must NOT be freed.
//
//export mihomo_free
func mihomo_free(ptr unsafe.Pointer) {
	if ptr != nil {
		C.free(ptr)
	}
}

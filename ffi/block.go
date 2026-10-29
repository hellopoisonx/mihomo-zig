// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 mihomo-zig contributors; see LICENSE.
package main

// Single-allocation result blocks for the typed queries.
//
// A query builds one C block holding a fixed-size record array, any nested
// record arrays, nested string-pointer arrays and the strings themselves.
// Callers therefore release an entire result with exactly one mihomo_free();
// no pointer stored inside the block may be freed separately.
//
// Records are allocated first, then strings, so the record array always starts
// at offset 0 and its address is the pointer the caller frees.

/*
#include <stdint.h>
#include <stdlib.h>
#include "mihomo_abi.h"
*/
import "C"

import (
	"errors"
	"reflect"
	"unsafe"
)

var errOutOfMemory = errors.New("out of memory")

const ptrSize = int(unsafe.Sizeof(uintptr(0)))

// cBlock is one C allocation plus the bump cursors used while filling it.
type cBlock struct {
	mem       unsafe.Pointer
	end       int
	recCursor int // nested record arrays
	recEnd    int
	ptrCursor int // nested pointer arrays
	strCursor int // strings
}

// newBlock allocates room for recordCount records of recordSize bytes, the
// nested record arrays announced by nestedRecordBytes, and everything reachable
// from rows: strings and slices of strings. Rows are measured by reflection, so
// callers never compute string sizes by hand.
func newBlock(recordCount, recordSize, nestedRecordBytes int, rows any) (*cBlock, error) {
	strBytes, ptrCount := measureRows(reflect.ValueOf(rows))
	records := recordCount * recordSize
	nested := align8(nestedRecordBytes)
	ptrBase := records + nested
	total := ptrBase + ptrCount*ptrSize + strBytes
	if total == 0 {
		total = 1
	}
	// calloc, not malloc: fields a given query does not set must stay zero, so
	// every pointer starts NULL and every flag/length starts 0.
	mem := C.calloc(1, C.size_t(total))
	if mem == nil {
		return nil, errOutOfMemory
	}
	return &cBlock{
		mem:       mem,
		end:       total,
		recCursor: records,
		recEnd:    ptrBase,
		ptrCursor: ptrBase,
		strCursor: ptrBase + ptrCount*ptrSize,
	}, nil
}

// nestedRecords hands out count records of size bytes from the nested record
// arena. The arena size must have been announced to newBlock.
func (b *cBlock) nestedRecords(count, size int) unsafe.Pointer {
	start := b.recCursor
	b.recCursor += count * size
	if b.recCursor > b.recEnd {
		panic("mihomo ffi: nested record arena under-measured")
	}
	return unsafe.Add(b.mem, start)
}

// str copies s into the block and returns its C string.
func (b *cBlock) str(s string) *C.char {
	start := b.strCursor
	end := start + len(s) + 1
	if end > b.end {
		panic("mihomo ffi: string arena under-measured")
	}
	buffer := unsafe.Slice((*byte)(b.mem), b.end)
	copy(buffer[start:], s)
	buffer[start+len(s)] = 0
	b.strCursor = end
	return (*C.char)(unsafe.Add(b.mem, start))
}

// strArray writes items as a NULL-terminated-free C string array and returns
// its first element (nil for an empty slice).
func (b *cBlock) strArray(items []string) **C.char {
	if len(items) == 0 {
		return nil
	}
	start := b.ptrCursor
	b.ptrCursor += len(items) * ptrSize
	if b.ptrCursor > b.strCursor {
		panic("mihomo ffi: pointer arena under-measured")
	}
	slots := unsafe.Slice((**C.char)(unsafe.Add(b.mem, start)), len(items))
	for i, item := range items {
		slots[i] = b.str(item)
	}
	return (**C.char)(unsafe.Add(b.mem, start))
}

// measureRows returns the bytes needed for every string reachable from v and
// the number of pointer slots needed by string slices found on the way.
func measureRows(v reflect.Value) (strBytes int, pointers int) {
	switch v.Kind() {
	case reflect.Interface, reflect.Pointer:
		if !v.IsNil() {
			return measureRows(v.Elem())
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			s, p := measureRows(v.Field(i))
			strBytes += s
			pointers += p
		}
	case reflect.Slice, reflect.Array:
		if v.Type().Elem().Kind() == reflect.String {
			for i := 0; i < v.Len(); i++ {
				strBytes += v.Index(i).Len() + 1
			}
			return strBytes, v.Len()
		}
		for i := 0; i < v.Len(); i++ {
			s, p := measureRows(v.Index(i))
			strBytes += s
			pointers += p
		}
	case reflect.String:
		strBytes += v.Len() + 1
	}
	return strBytes, pointers
}

func align8(n int) int {
	return (n + 7) &^ 7
}

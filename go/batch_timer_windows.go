package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	qpcCounterProc   = syscall.NewLazyDLL("kernel32.dll").NewProc("QueryPerformanceCounter")
	qpcFrequencyProc = syscall.NewLazyDLL("kernel32.dll").NewProc("QueryPerformanceFrequency")
)

func newBatchTimer() (func() (uint64, error), uint64, string, error) {
	var frequency int64
	result, _, callErr := qpcFrequencyProc.Call(uintptr(unsafe.Pointer(&frequency)))
	if result == 0 {
		return nil, 0, "", fmt.Errorf("QueryPerformanceFrequency failed: %v", callErr)
	}
	if frequency <= 0 {
		return nil, 0, "", fmt.Errorf("QueryPerformanceFrequency returned invalid frequency %d", frequency)
	}

	read := func() (uint64, error) {
		var counter int64
		result, _, callErr := qpcCounterProc.Call(uintptr(unsafe.Pointer(&counter)))
		if result == 0 {
			return 0, fmt.Errorf("QueryPerformanceCounter failed: %v", callErr)
		}
		return uint64(counter), nil
	}
	return read, uint64(frequency), "QueryPerformanceCounter", nil
}

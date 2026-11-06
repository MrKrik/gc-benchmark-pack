//go:build !windows

package main

import (
	"fmt"
	"time"
)

func newBatchTimer() (func() (uint64, error), uint64, string, error) {
	origin := time.Now()
	return func() (uint64, error) {
		elapsed := time.Since(origin)
		if elapsed < 0 {
			return 0, fmt.Errorf("monotonic timer returned a negative duration")
		}
		return uint64(elapsed.Nanoseconds()), nil
	}, 1_000_000_000, "Go monotonic clock", nil
}

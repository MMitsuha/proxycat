package libmihomo

import (
	"context"
	runtimeDebug "runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	smemory "github.com/metacubex/sing/common/memory"
)

// OOM watchdog for the Network Extension process.
//
// iOS jetsam compares a process' phys_footprint against an undocumented
// per-process budget. Swift estimates that budget as
// resident + os_proc_available_memory() at tunnel start and passes it through
// SetMemoryLimit. The Go side then handles the memory-heavy mihomo runtime:
//
//  1. Configure a soft runtime memory limit before the trigger point so GC
//     starts working harder before jetsam.
//  2. Poll phys_footprint inside the extension process; this keeps the guard
//     independent of Swift dispatch-source delivery.
//  3. On critical pressure, force a GC, close tracked connections, then force
//     another GC so connection buffers can be returned to the kernel.

const (
	defaultMemoryLimit  = 50 * 1024 * 1024
	defaultMemorySafety = 5 * 1024 * 1024

	oomFastPoll = 100 * time.Millisecond
	oomWarnPoll = 1 * time.Second
	oomSlowPoll = 10 * time.Second
)

type oomPressure uint8

const (
	oomPressureNormal oomPressure = iota
	oomPressureWarning
	oomPressureCritical
)

type oomPolicy struct {
	limit     uint64
	safety    uint64
	warnAt    uint64
	triggerAt uint64
	resumeAt  uint64
}

type oomWatchdog struct {
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}

	policyMu sync.RWMutex
	policy   oomPolicy

	state atomic.Uint32 // oomPressure
}

var (
	killer atomic.Pointer[oomWatchdog]

	memoryLimitMu sync.Mutex
	memoryLimit   int64 // 0 means use defaultMemoryLimit
)

// SetMemoryLimit configures the per-process memory budget (bytes) used by the
// OOM watchdog. Pass 0 to fall back to the iOS-NE default of 50 MB. Calls made
// while the watchdog is running take effect immediately.
func SetMemoryLimit(limit int64) {
	if limit < 0 {
		limit = 0
	}
	memoryLimitMu.Lock()
	memoryLimit = limit
	memoryLimitMu.Unlock()

	policy := newOOMPolicy(limit)
	memBudget.Store(int64(policy.limit))
	if watchdog := killer.Load(); watchdog != nil {
		watchdog.updatePolicy(policy)
	}
}

// MemoryUsage returns the process phys_footprint in bytes. It is the same
// value iOS jetsam compares to the per-process memory budget.
func MemoryUsage() int64 {
	return int64(smemory.Total())
}

func startOOMKiller() {
	policy := configuredOOMPolicy()
	watchdog := newOOMWatchdog(policy)
	if !killer.CompareAndSwap(nil, watchdog) {
		return
	}

	memBudget.Store(int64(policy.limit))
	runtimeDebug.SetMemoryLimit(int64(policy.warnAt))
	log.Infoln("[OOM] watchdog armed: limit=%dMB warn=%dMB trigger=%dMB resume=%dMB",
		policy.limit/1024/1024,
		policy.warnAt/1024/1024,
		policy.triggerAt/1024/1024,
		policy.resumeAt/1024/1024,
	)

	go watchdog.run()
}

func stopOOMKiller() {
	watchdog := killer.Swap(nil)
	if watchdog == nil {
		return
	}
	watchdog.stop()
	runtimeDebug.SetMemoryLimit(-1)
}

func configuredOOMPolicy() oomPolicy {
	memoryLimitMu.Lock()
	limit := memoryLimit
	memoryLimitMu.Unlock()
	return newOOMPolicy(limit)
}

func newOOMWatchdog(policy oomPolicy) *oomWatchdog {
	ctx, cancel := context.WithCancel(context.Background())
	watchdog := &oomWatchdog{
		ctx:    ctx,
		cancel: cancel,
		done:   make(chan struct{}),
		policy: policy,
	}
	watchdog.state.Store(uint32(oomPressureNormal))
	return watchdog
}

func (w *oomWatchdog) stop() {
	w.cancel()
	<-w.done
}

func (w *oomWatchdog) updatePolicy(policy oomPolicy) {
	w.policyMu.Lock()
	w.policy = policy
	w.policyMu.Unlock()
	runtimeDebug.SetMemoryLimit(int64(policy.warnAt))
	log.Infoln("[OOM] watchdog budget updated: limit=%dMB warn=%dMB trigger=%dMB",
		policy.limit/1024/1024,
		policy.warnAt/1024/1024,
		policy.triggerAt/1024/1024,
	)
}

func (w *oomWatchdog) currentPolicy() oomPolicy {
	w.policyMu.RLock()
	defer w.policyMu.RUnlock()
	return w.policy
}

func (w *oomWatchdog) run() {
	defer close(w.done)

	timer := time.NewTimer(oomFastPoll)
	defer timer.Stop()

	interval := oomFastPoll
	for {
		select {
		case <-w.ctx.Done():
			return
		case <-timer.C:
			usage := uint64(smemory.Total())
			policy := w.currentPolicy()
			pressure := w.evaluate(policy, usage)
			interval = nextOOMInterval(interval, pressure)
			timer.Reset(interval)
		}
	}
}

func (w *oomWatchdog) evaluate(policy oomPolicy, usage uint64) oomPressure {
	previous := oomPressure(w.state.Load())
	next := policy.classify(previous, usage)
	w.state.Store(uint32(next))

	if next == oomPressureCritical && previous != oomPressureCritical {
		respondToMemoryPressure(policy, usage)
	}
	return next
}

func newOOMPolicy(limit int64) oomPolicy {
	if limit <= 0 {
		limit = defaultMemoryLimit
	}
	budget := uint64(limit)
	safety := uint64(defaultMemorySafety)
	if maxSafety := budget / 4; safety > maxSafety {
		safety = maxSafety
	}
	if safety == 0 {
		safety = 1
	}

	return oomPolicy{
		limit:     budget,
		safety:    safety,
		warnAt:    saturatingSub(budget, 2*safety),
		triggerAt: saturatingSub(budget, safety),
		resumeAt:  saturatingSub(budget, 4*safety),
	}
}

func (p oomPolicy) classify(previous oomPressure, usage uint64) oomPressure {
	if previous == oomPressureCritical && usage >= p.resumeAt {
		return oomPressureCritical
	}
	if usage >= p.triggerAt {
		return oomPressureCritical
	}
	if usage >= p.warnAt {
		return oomPressureWarning
	}
	return oomPressureNormal
}

func nextOOMInterval(current time.Duration, pressure oomPressure) time.Duration {
	switch pressure {
	case oomPressureCritical:
		return oomFastPoll
	case oomPressureWarning:
		return oomWarnPoll
	default:
		if current < oomFastPoll {
			current = oomFastPoll
		}
		next := current * 2
		if next > oomSlowPoll {
			next = oomSlowPoll
		}
		return next
	}
}

func respondToMemoryPressure(policy oomPolicy, usage uint64) {
	log.Warnln("[OOM] pressure critical: usage=%dMB/%dMB — releasing memory and closing connections",
		usage/1024/1024,
		policy.limit/1024/1024,
	)

	runtimeDebug.FreeOSMemory()
	closed := CloseAllConnections()
	if closed > 0 {
		log.Warnln("[OOM] closed %d active connections", closed)
	}
	runtimeDebug.FreeOSMemory()
}

func saturatingSub(a, b uint64) uint64 {
	if a < b {
		return 0
	}
	return a - b
}

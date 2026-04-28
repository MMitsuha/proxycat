package libmihomo

import (
	runtimeDebug "runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
	smemory "github.com/metacubex/sing/common/memory"
)

// OOM-killer ported from sing-box's service/oomkiller (Apache-2.0).
// The defense has three layers:
//
//  1. Soft GC: runtime/debug.SetMemoryLimit(armed) tells the Go GC to try
//     harder long before jetsam wakes up. It's a hint, not a hard cap.
//  2. Adaptive timer: phys_footprint (mach task_vm_info) is polled every
//     100 ms / 1 s / 10 s depending on pressure state. Pure Go, no
//     reliance on the Swift dispatch source.
//  3. Trigger response: runtime/debug.FreeOSMemory() to return slabs to
//     the kernel + statistic.DefaultManager.Range(close) to drop every
//     active proxy connection. This is roughly equivalent to sing-box's
//     router.ResetNetwork() which it does for the same reason.
//
// Memory limits on iOS NE are undocumented (~15–50 MB historically). The
// caller (Swift PacketTunnelProvider) supplies the actual budget by
// summing phys_footprint + os_proc_available_memory at Start.

const (
	defaultMemoryLimit = 50 * 1024 * 1024
	defaultSafety      = 5 * 1024 * 1024

	oomMinPoll   = 100 * time.Millisecond
	oomArmedPoll = 1 * time.Second
	oomMaxPoll   = 10 * time.Second
)

type pressureState uint8

const (
	pressureNormal pressureState = iota
	pressureArmed
	pressureTriggered
)

type oomKiller struct {
	limit     uint64
	safety    uint64
	triggerAt uint64
	armedAt   uint64
	resumeAt  uint64

	state    atomic.Uint32 // pressureState
	interval atomic.Int64  // time.Duration
	running  atomic.Bool

	mu    sync.Mutex
	timer *time.Timer
}

var (
	killer        atomic.Pointer[oomKiller]
	memoryLimitMu sync.Mutex
	memoryLimit   int64 // 0 means use default
)

// SetMemoryLimit configures the per-process memory budget (bytes) used by
// the OOM killer. Pass 0 to fall back to the iOS-NE default of 50 MB
// (matches sing-box). Call before Start; later calls take effect on the
// next Start.
func SetMemoryLimit(limit int64) {
	memoryLimitMu.Lock()
	memoryLimit = limit
	memoryLimitMu.Unlock()
}

// MemoryUsage returns the process's phys_footprint in bytes — the same
// value iOS jetsam compares to the per-process memory limit. Same source
// the OOM killer reads, so dashboards using this match the killer's view.
func MemoryUsage() int64 {
	return int64(smemory.Total())
}

func startOOMKiller() {
	memoryLimitMu.Lock()
	limit := uint64(memoryLimit)
	memoryLimitMu.Unlock()
	if limit == 0 {
		limit = defaultMemoryLimit
	}

	safety := uint64(defaultSafety)
	if safety > limit/4 {
		safety = limit / 4
	}

	k := &oomKiller{
		limit:     limit,
		safety:    safety,
		triggerAt: limit - safety,
		armedAt:   sub(limit, 2*safety),
		resumeAt:  sub(limit, 4*safety),
	}
	k.interval.Store(int64(oomMaxPoll))

	if !killer.CompareAndSwap(nil, k) {
		return // already running
	}

	// Tell the Go GC the budget. This is a soft cap; the runtime tries to
	// keep heap below it but won't OOM-kill itself. The point is to make
	// the GC ramp up before the kernel does.
	runtimeDebug.SetMemoryLimit(int64(k.armedAt))

	log.Infoln("[OOM] watchdog armed: limit=%dMB trigger=%dMB armed=%dMB",
		k.limit/1024/1024, k.triggerAt/1024/1024, k.armedAt/1024/1024)

	k.running.Store(true)
	k.schedule(oomMinPoll)
}

func stopOOMKiller() {
	k := killer.Swap(nil)
	if k == nil {
		return
	}
	k.running.Store(false)
	k.mu.Lock()
	if k.timer != nil {
		k.timer.Stop()
		k.timer = nil
	}
	k.mu.Unlock()
	// Lift the runtime cap.
	runtimeDebug.SetMemoryLimit(-1)
}

func (k *oomKiller) schedule(delay time.Duration) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.running.Load() {
		return
	}
	if k.timer == nil {
		k.timer = time.AfterFunc(delay, k.poll)
		return
	}
	k.timer.Reset(delay)
}

func (k *oomKiller) poll() {
	if !k.running.Load() {
		return
	}

	usage := smemory.Total()
	prev := pressureState(k.state.Load())
	next := k.classify(prev, usage)
	k.state.Store(uint32(next))

	if next == pressureTriggered && prev != pressureTriggered {
		k.respond(usage)
	}

	k.schedule(k.intervalFor(next))
}

func (k *oomKiller) classify(prev pressureState, usage uint64) pressureState {
	if prev == pressureTriggered {
		if usage >= k.resumeAt {
			return pressureTriggered
		}
		return pressureNormal
	}
	if usage >= k.triggerAt {
		return pressureTriggered
	}
	if usage >= k.armedAt {
		return pressureArmed
	}
	return pressureNormal
}

func (k *oomKiller) intervalFor(state pressureState) time.Duration {
	switch state {
	case pressureTriggered:
		return oomMinPoll
	case pressureArmed:
		return oomArmedPoll
	default:
		// Exponential back-off up to oomMaxPoll while normal.
		cur := time.Duration(k.interval.Load())
		if cur < oomMinPoll {
			cur = oomMinPoll
		}
		next := cur * 2
		if next > oomMaxPoll {
			next = oomMaxPoll
		}
		k.interval.Store(int64(next))
		return next
	}
}

func (k *oomKiller) respond(usage uint64) {
	log.Warnln("[OOM] threshold crossed: usage=%dMB/%dMB — releasing OS memory + dropping connections",
		usage/1024/1024, k.limit/1024/1024)

	// 1) Run the GC and hand pages back to the kernel right now.
	runtimeDebug.FreeOSMemory()

	// 2) Drop every active proxy connection. mihomo's per-connection
	//    buffers are the biggest chunk of resident memory in steady
	//    state; closing them frees the most for the least disruption.
	if mgr := statistic.DefaultManager; mgr != nil {
		count := 0
		mgr.Range(func(t statistic.Tracker) bool {
			_ = t.Close()
			count++
			return true
		})
		if count > 0 {
			log.Warnln("[OOM] closed %d active connections", count)
		}
	}

	// 3) Second FreeOSMemory after closing connections — the slabs that
	//    backed those tracker buffers should now be returnable.
	runtimeDebug.FreeOSMemory()
}

func sub(a, b uint64) uint64 {
	if a < b {
		return 0
	}
	return a - b
}

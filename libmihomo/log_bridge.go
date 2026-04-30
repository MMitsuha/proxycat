package libmihomo

import (
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/log"
)

// LogDelegate receives every log event emitted by mihomo. The delegate is
// implemented in Swift; gomobile generates a Swift protocol with a method:
//
//	func onLog(_ level: Int, message: String?)
//
// Implementations MUST NOT block. Swift implementations should hop the work
// to the main queue via DispatchQueue.main.async if they touch UI state.
type LogDelegate interface {
	OnLog(level int, message string)
}

var (
	logSubsMu sync.Mutex
	logSubs   = map[int64]*logPump{}
	nextSubID int64
)

// SubscribeLogs registers a delegate that will receive every log event
// emitted from this point onward. Returns an opaque ID; pass it to
// UnsubscribeLogs to detach. If the delegate is nil, returns 0.
func SubscribeLogs(delegate LogDelegate) int64 {
	if delegate == nil {
		return 0
	}
	id := atomic.AddInt64(&nextSubID, 1)
	pump := startLogPump(func(event log.Event) {
		delegate.OnLog(int(event.LogLevel), event.Payload)
	})

	logSubsMu.Lock()
	logSubs[id] = pump
	logSubsMu.Unlock()
	return id
}

// UnsubscribeLogs detaches a delegate previously registered.
func UnsubscribeLogs(id int64) {
	logSubsMu.Lock()
	pump, ok := logSubs[id]
	if ok {
		delete(logSubs, id)
	}
	logSubsMu.Unlock()
	if !ok {
		return
	}
	pump.Close()
}

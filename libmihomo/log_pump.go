package libmihomo

import (
	"sync"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/log"
)

// logPump owns one subscription to mihomo's log observable and a
// goroutine that calls a handler on every event. The Swift bridge
// (log_bridge.go) and the on-disk persistence (log_persist.go) each
// need exactly this — same select{stop, event} loop with the same
// defensive recover — so they share this helper instead of inlining
// the lifecycle twice.
//
// Close drains the goroutine before returning, so callers can rely on
// "after Close, the handler will not be invoked again" without an
// extra synchronisation hop.
type logPump struct {
	sub       observable.Subscription[log.Event]
	stop      chan struct{}
	done      chan struct{}
	closeOnce sync.Once
}

// startLogPump subscribes to mihomo's log observable and spawns a
// goroutine that calls handler on every event. handler must not
// block; if it panics, the recover keeps the package alive without
// taking down the Network Extension.
func startLogPump(handler func(log.Event)) *logPump {
	p := &logPump{
		sub:  log.Subscribe(),
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	go p.run(handler)
	return p
}

func (p *logPump) run(handler func(log.Event)) {
	defer close(p.done)
	defer func() {
		// Defensive: a faulty handler must not crash mihomo.
		recover()
	}()
	for {
		select {
		case <-p.stop:
			return
		case event, ok := <-p.sub:
			if !ok {
				return
			}
			handler(event)
		}
	}
}

// Close terminates the pump, unsubscribes from the observable, and
// blocks until the goroutine has fully exited. Safe to call multiple
// times — second and later calls return immediately after waiting on
// done (which is already closed).
func (p *logPump) Close() {
	p.closeOnce.Do(func() {
		close(p.stop)
		log.UnSubscribe(p.sub)
	})
	<-p.done
}

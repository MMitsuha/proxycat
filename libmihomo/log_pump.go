package libmihomo

import (
	"sync"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/log"
)

// logPump owns one subscription to mihomo's log observable and a
// drain goroutine plus one handler goroutine. The drain goroutine never
// calls arbitrary code; it only copies events into an internal FIFO. That
// keeps mihomo's small per-subscriber observable buffer from filling if a
// file write or Swift delegate callback stalls.
//
// Close unsubscribes, then drains the queued events before returning, so
// callers can rely on "after Close, the handler will not be invoked again"
// without an extra synchronisation hop.
type logPump struct {
	sub       observable.Subscription[log.Event]
	queue     *logEventQueue
	done      chan struct{}
	closeOnce sync.Once
}

// startLogPump subscribes to mihomo's log observable and spawns a
// drain goroutine plus a handler goroutine. handler may perform file I/O
// or hop into Swift; if it panics, the recover keeps the package alive
// without taking down the Network Extension.
func startLogPump(handler func(log.Event)) *logPump {
	p := &logPump{
		sub:   log.Subscribe(),
		queue: newLogEventQueue(),
		done:  make(chan struct{}),
	}
	go p.drain()
	go p.run(handler)
	return p
}

func (p *logPump) drain() {
	defer p.queue.Close()
	for event := range p.sub {
		p.queue.Push(event)
	}
}

func (p *logPump) run(handler func(log.Event)) {
	defer close(p.done)
	for {
		event, ok := p.queue.Pop()
		if !ok {
			return
		}
		safeHandleLogEvent(handler, event)
	}
}

func safeHandleLogEvent(handler func(log.Event), event log.Event) {
	defer func() {
		// Defensive: a faulty callback must not crash mihomo or
		// permanently kill the subscription.
		_ = recover()
	}()
	handler(event)
}

// Close terminates the pump, unsubscribes from the observable, and
// blocks until queued events have been handled. Safe to call multiple
// times — second and later calls return immediately after waiting on
// done (which is already closed).
func (p *logPump) Close() {
	p.closeOnce.Do(func() {
		log.UnSubscribe(p.sub)
	})
	<-p.done
}

type logEventQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	events []log.Event
	head   int
	closed bool
}

func newLogEventQueue() *logEventQueue {
	q := &logEventQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *logEventQueue) Push(event log.Event) {
	q.mu.Lock()
	if !q.closed {
		q.events = append(q.events, event)
		q.cond.Signal()
	}
	q.mu.Unlock()
}

func (q *logEventQueue) Pop() (log.Event, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.head == len(q.events) && !q.closed {
		q.cond.Wait()
	}
	if q.head == len(q.events) {
		return log.Event{}, false
	}
	event := q.events[q.head]
	q.head++
	if q.head > 1024 && q.head*2 >= len(q.events) {
		copy(q.events, q.events[q.head:])
		q.events = q.events[:len(q.events)-q.head]
		q.head = 0
	}
	return event, true
}

func (q *logEventQueue) Close() {
	q.mu.Lock()
	q.closed = true
	q.cond.Broadcast()
	q.mu.Unlock()
}

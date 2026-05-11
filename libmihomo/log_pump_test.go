package libmihomo

import (
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/log"
)

func TestSafeHandleLogEventRecoversPerEvent(t *testing.T) {
	calls := 0
	safeHandleLogEvent(func(log.Event) {
		calls++
		panic("callback failed")
	}, log.Event{LogLevel: log.INFO, Payload: "first"})

	safeHandleLogEvent(func(log.Event) {
		calls++
	}, log.Event{LogLevel: log.INFO, Payload: "second"})

	if calls != 2 {
		t.Fatalf("handler calls = %d, want 2", calls)
	}
}

func TestLogEventQueueDrainsQueuedEventsAfterClose(t *testing.T) {
	q := newLogEventQueue()
	q.Push(log.Event{Payload: "one"})
	q.Push(log.Event{Payload: "two"})
	q.Close()

	var got []string
	for {
		event, ok := q.Pop()
		if !ok {
			break
		}
		got = append(got, event.Payload)
	}

	if want := []string{"one", "two"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("queue drained %v, want %v", got, want)
	}
}

func TestLogEventQueueRejectsPushAfterClose(t *testing.T) {
	q := newLogEventQueue()
	q.Close()
	q.Push(log.Event{Payload: "ignored"})

	if event, ok := q.Pop(); ok {
		t.Fatalf("closed queue returned event %q", event.Payload)
	}
}

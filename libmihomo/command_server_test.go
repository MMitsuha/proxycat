package libmihomo

import (
	"context"
	"testing"
	"time"

	mihomolog "github.com/metacubex/mihomo/log"
)

func TestEnqueueLatestLogEventDropsOldestWhenFull(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	out := make(chan stampedLogEvent, 1)
	out <- stampedLogEvent{event: mihomolog.Event{Payload: "old"}}

	enqueueLatestLogEvent(ctx, out, stampedLogEvent{event: mihomolog.Event{Payload: "new"}})

	select {
	case got := <-out:
		if got.event.Payload != "new" {
			t.Fatalf("payload = %q, want newest event", got.event.Payload)
		}
	default:
		t.Fatal("queue unexpectedly empty")
	}
}

func TestEnqueueLatestLogEventReturnsWhenCanceledAndFull(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	out := make(chan stampedLogEvent)
	done := make(chan struct{})
	go func() {
		enqueueLatestLogEvent(ctx, out, stampedLogEvent{event: mihomolog.Event{Payload: "ignored"}})
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("enqueue did not return after cancellation")
	}
}

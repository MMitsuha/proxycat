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

	out := make(chan mihomolog.Event, 1)
	out <- mihomolog.Event{Payload: "old"}

	enqueueLatestLogEvent(ctx, out, mihomolog.Event{Payload: "new"})

	select {
	case got := <-out:
		if got.Payload != "new" {
			t.Fatalf("payload = %q, want newest event", got.Payload)
		}
	default:
		t.Fatal("queue unexpectedly empty")
	}
}

func TestEnqueueLatestLogEventReturnsWhenCanceledAndFull(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	out := make(chan mihomolog.Event)
	done := make(chan struct{})
	go func() {
		enqueueLatestLogEvent(ctx, out, mihomolog.Event{Payload: "ignored"})
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("enqueue did not return after cancellation")
	}
}

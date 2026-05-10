package libmihomo

import (
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

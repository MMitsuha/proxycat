package libmihomo

import (
	"testing"
	"time"
)

func TestNewOOMPolicyDefaultsAndThresholds(t *testing.T) {
	policy := newOOMPolicy(0)
	if policy.limit != defaultMemoryLimit {
		t.Fatalf("limit = %d, want %d", policy.limit, defaultMemoryLimit)
	}
	if policy.safety != defaultMemorySafety {
		t.Fatalf("safety = %d, want %d", policy.safety, defaultMemorySafety)
	}
	if policy.triggerAt != policy.limit-policy.safety {
		t.Fatalf("triggerAt = %d, want %d", policy.triggerAt, policy.limit-policy.safety)
	}
	if policy.warnAt != policy.limit-2*policy.safety {
		t.Fatalf("warnAt = %d, want %d", policy.warnAt, policy.limit-2*policy.safety)
	}
	if policy.resumeAt != policy.limit-4*policy.safety {
		t.Fatalf("resumeAt = %d, want %d", policy.resumeAt, policy.limit-4*policy.safety)
	}
}

func TestNewOOMPolicyCapsSafetyForSmallBudgets(t *testing.T) {
	const limit = 8 * 1024 * 1024
	policy := newOOMPolicy(limit)
	if policy.safety != limit/4 {
		t.Fatalf("safety = %d, want %d", policy.safety, limit/4)
	}
	if policy.resumeAt != 0 {
		t.Fatalf("resumeAt = %d, want 0", policy.resumeAt)
	}
}

func TestOOMPolicyClassifyAndHysteresis(t *testing.T) {
	policy := newOOMPolicy(50 * 1024 * 1024)

	if got := policy.classify(oomPressureNormal, policy.warnAt-1); got != oomPressureNormal {
		t.Fatalf("below warn = %v, want normal", got)
	}
	if got := policy.classify(oomPressureNormal, policy.warnAt); got != oomPressureWarning {
		t.Fatalf("at warn = %v, want warning", got)
	}
	if got := policy.classify(oomPressureWarning, policy.triggerAt); got != oomPressureCritical {
		t.Fatalf("at trigger = %v, want critical", got)
	}
	if got := policy.classify(oomPressureCritical, policy.resumeAt); got != oomPressureCritical {
		t.Fatalf("at resume while critical = %v, want critical", got)
	}
	if got := policy.classify(oomPressureCritical, policy.resumeAt-1); got != oomPressureNormal {
		t.Fatalf("below resume while critical = %v, want normal", got)
	}
}

func TestNextOOMInterval(t *testing.T) {
	if got := nextOOMInterval(oomSlowPoll, oomPressureCritical); got != oomFastPoll {
		t.Fatalf("critical interval = %v, want %v", got, oomFastPoll)
	}
	if got := nextOOMInterval(oomFastPoll, oomPressureWarning); got != oomWarnPoll {
		t.Fatalf("warning interval = %v, want %v", got, oomWarnPoll)
	}
	if got := nextOOMInterval(50*time.Millisecond, oomPressureNormal); got != 2*oomFastPoll {
		t.Fatalf("normal first interval = %v, want %v", got, 2*oomFastPoll)
	}
	if got := nextOOMInterval(8*time.Second, oomPressureNormal); got != oomSlowPoll {
		t.Fatalf("normal capped interval = %v, want %v", got, oomSlowPoll)
	}
}

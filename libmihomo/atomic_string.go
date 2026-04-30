package libmihomo

import "sync/atomic"

// atomicString is a tiny lock-free wrapper around atomic.Pointer[string]
// for the package's "set once via gomobile, read on every Start/Reload"
// path strings (home dir, command socket, profile pointer, etc.).
//
// The zero value is ready to use and Load returns "" until something has
// been Stored. Replaces the (sync.Mutex + plain string) pairs that used
// to repeat across binding.go / log_persist.go / settings.go for the
// same essentially-atomic-string semantic.
type atomicString struct {
	p atomic.Pointer[string]
}

func (a *atomicString) Store(s string) {
	a.p.Store(&s)
}

func (a *atomicString) Load() string {
	if p := a.p.Load(); p != nil {
		return *p
	}
	return ""
}

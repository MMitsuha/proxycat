package libmihomo

import (
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
)

// NotifyDefaultInterfaceChanged tells mihomo that the OS-supplied default
// network interface (Wi-Fi → cellular, post-sleep reconnect, etc.) has
// changed. It mirrors what mihomo's own DefaultInterfaceMonitor callback
// does on Linux/macOS — but on iOS that monitor can't run inside the
// Network Extension sandbox, so the host has to drive these refreshes
// from a Swift NWPathMonitor.
//
// Three effects:
//
//  1. iface.FlushCache() drops the cached interface table so the next
//     dialer that asks for "the default interface" re-reads the live one.
//  2. resolver.ResetConnection() asks every long-lived DNS upstream
//     (DoH/DoT/DoQ) to re-establish its underlying TCP/QUIC connection,
//     which would otherwise stay bound to a now-dead route and silently
//     hang.
//  3. statistic.DefaultManager close-all force-terminates every tracked
//     tunneled connection. iOS-only — Linux/macOS leaves them, relying on
//     the kernel to surface socket errors quickly. iOS instead tends to
//     keep the dead socket "alive but unwritable" until the multi-minute
//     TCP retransmit timeout, so apps with persistent connections
//     (iMessage, push, streaming) hang. Closing the trackers propagates
//     EOF to the inbound side so the apps re-dial through the fresh
//     route immediately.
//
// No-op when the core isn't started so spurious early NWPathMonitor
// callbacks before Start() don't reach uninitialized resolver state.
func NotifyDefaultInterfaceChanged() {
	if !started.Load() {
		return
	}
	iface.FlushCache()
	resolver.ResetConnection()
	CloseAllConnections()
}

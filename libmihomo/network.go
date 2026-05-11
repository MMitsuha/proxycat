package libmihomo

import (
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

// NotifyDefaultInterfaceChanged tells mihomo that the OS-supplied default
// network interface (Wi-Fi → cellular, post-sleep reconnect, etc.) may have
// changed. It mirrors the non-destructive part of mihomo's own
// DefaultInterfaceMonitor callback on Linux/macOS — but on iOS that monitor
// can't run inside the Network Extension sandbox, so the host has to drive
// these refreshes from a Swift NWPathMonitor.
//
// Two effects:
//
//  1. iface.FlushCache() drops the cached interface table so the next
//     dialer that asks for "the default interface" re-reads the live one.
//  2. resolver.ResetConnection() asks every long-lived DNS upstream
//     (DoH/DoT/DoQ) to re-establish its underlying TCP/QUIC connection,
//     which would otherwise stay bound to a now-dead route and silently
//     hang.
//
// Closing active tunneled connections is intentionally separate. iOS can emit
// repeated NWPathMonitor callbacks for the same still-satisfied path while the
// host app backgrounds. Treating every callback as destructive causes apparent
// disconnects. The Swift extension now closes trackers only for real path
// transitions, with throttling.
//
// No-op when the core isn't started so spurious early NWPathMonitor
// callbacks before Start() don't reach uninitialized resolver state.
func NotifyDefaultInterfaceChanged() {
	if !started.Load() {
		log.Infoln("[network] default interface change ignored: mihomo not started")
		return
	}
	iface.FlushCache()
	resolver.ResetConnection()
	log.Infoln("[network] default interface changed: flushed interface cache, reset DNS upstreams")
}

package libmihomo

import (
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Traffic is a snapshot of cumulative + instantaneous transfer.
// Flat fields only — required for gomobile.
type Traffic struct {
	Up            int64 // bytes/sec, current second
	Down          int64
	UploadTotal   int64
	DownloadTotal int64
	Connections   int64
}

// TrafficNow returns the current traffic snapshot.
func TrafficNow() *Traffic {
	mgr := statistic.DefaultManager
	if mgr == nil {
		return &Traffic{}
	}
	up, down := mgr.Now()
	upTotal, downTotal := mgr.Total()

	conns := int64(0)
	mgr.Range(func(_ statistic.Tracker) bool {
		conns++
		return true
	})

	return &Traffic{
		Up:            up,
		Down:          down,
		UploadTotal:   upTotal,
		DownloadTotal: downTotal,
		Connections:   conns,
	}
}

// CloseAllConnections drops every active connection. Useful when memory
// pressure climbs in the iOS extension.
func CloseAllConnections() {
	mgr := statistic.DefaultManager
	if mgr == nil {
		return
	}
	mgr.Range(func(t statistic.Tracker) bool {
		_ = t.Close()
		return true
	})
}

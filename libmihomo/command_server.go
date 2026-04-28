package libmihomo

import (
	"errors"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"google.golang.org/grpc"

	pb "github.com/proxycat/libmihomo/proto/command"
)

// CommandServer runs inside the Network Extension. It speaks gRPC over a
// Unix-domain socket placed in the App Group container so the host app's
// CommandClient can subscribe to streaming status / log events.
//
// Architecture mirrors sing-box's experimental/libbox.CommandServer.
// Mihomo's REST controller (external-controller, port 9090) is *not*
// reused — that interface is for end-users; this socket is private IPC.

const (
	statusMinInterval = 100 * time.Millisecond
	statusMaxInterval = 10 * time.Second
	statusDefault     = 1 * time.Second
)

type commandServer struct {
	listener   net.Listener
	grpcServer *grpc.Server
}

var (
	cmdSrv     atomic.Pointer[commandServer]
	memBudget  atomic.Int64 // set by SetMemoryLimit, surfaced to clients via StatusMessage
)

// StartCommandServer starts a gRPC server listening on `socketPath`.
// Idempotent — second call while running is a no-op. Cleans up any stale
// socket file from a prior crashed run.
func StartCommandServer(socketPath string) error {
	if cmdSrv.Load() != nil {
		return nil
	}
	_ = os.Remove(socketPath) // stale leftover

	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	// Tighten permissions: only the App-Group sandbox can access it,
	// but be explicit anyway.
	_ = os.Chmod(socketPath, 0o600)

	gs := grpc.NewServer()
	pb.RegisterCommandServer(gs, &commandServiceImpl{})

	srv := &commandServer{listener: l, grpcServer: gs}
	if !cmdSrv.CompareAndSwap(nil, srv) {
		// Lost a race; tear ours down.
		gs.Stop()
		l.Close()
		return nil
	}

	go func() {
		if err := gs.Serve(l); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			log.Errorln("[command] grpc Serve: %v", err)
		}
	}()
	log.Infoln("[command] server listening on %s", socketPath)
	return nil
}

// StopCommandServer gracefully tears down the server. Streams in flight
// finish their current send and exit.
func StopCommandServer() {
	srv := cmdSrv.Swap(nil)
	if srv == nil {
		return
	}
	srv.grpcServer.GracefulStop()
	_ = srv.listener.Close()
}

// commandServiceImpl is the concrete implementation of pb.CommandServer.
type commandServiceImpl struct {
	pb.UnimplementedCommandServer
}

// SubscribeStatus pushes a StatusMessage at every tick.
func (s *commandServiceImpl) SubscribeStatus(req *pb.StatusRequest, stream pb.Command_SubscribeStatusServer) error {
	interval := time.Duration(req.GetIntervalMs()) * time.Millisecond
	switch {
	case interval <= 0:
		interval = statusDefault
	case interval < statusMinInterval:
		interval = statusMinInterval
	case interval > statusMaxInterval:
		interval = statusMaxInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Send one immediately so the dashboard isn't blank for the first
	// `interval` after subscription.
	if err := stream.Send(buildStatus()); err != nil {
		return err
	}

	for {
		select {
		case <-stream.Context().Done():
			return nil
		case <-ticker.C:
			if err := stream.Send(buildStatus()); err != nil {
				return err
			}
		}
	}
}

// SubscribeLogs forwards every log event from mihomo's observable to the
// stream. Each subscription opens its own observable subscription so
// subscribers can come and go without affecting each other.
func (s *commandServiceImpl) SubscribeLogs(_ *pb.LogRequest, stream pb.Command_SubscribeLogsServer) error {
	sub := log.Subscribe()
	defer log.UnSubscribe(sub)

	for {
		select {
		case <-stream.Context().Done():
			return nil
		case event, ok := <-sub:
			if !ok {
				return nil
			}
			err := stream.Send(&pb.LogMessage{
				Level:   int32(event.LogLevel),
				Payload: event.Payload,
			})
			if err != nil {
				return err
			}
		}
	}
}

func buildStatus() *pb.StatusMessage {
	t := TrafficNow()
	if t == nil {
		t = &Traffic{}
	}
	return &pb.StatusMessage{
		Up:             t.Up,
		Down:           t.Down,
		UpTotal:        t.UploadTotal,
		DownTotal:      t.DownloadTotal,
		Connections:    t.Connections,
		MemoryResident: MemoryUsage(),
		MemoryBudget:   memBudget.Load(),
	}
}

// Note: noisy idle-server detection
var _ = sync.Mutex{}

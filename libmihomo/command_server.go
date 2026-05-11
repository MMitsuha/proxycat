package libmihomo

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

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
	commandStopGrace  = 750 * time.Millisecond

	controllerMaxMessageBytes = 32 * 1024 * 1024
	logStreamBuffer           = 128
)

type commandServer struct {
	listener   net.Listener
	grpcServer *grpc.Server
}

var (
	cmdSrvMu  sync.Mutex
	cmdSrv    atomic.Pointer[commandServer]
	memBudget atomic.Int64 // set by SetMemoryLimit, surfaced to clients via StatusMessage
)

// StartCommandServer starts a gRPC server listening on `socketPath`.
// Idempotent — second call while running is a no-op. Cleans up any stale
// socket file from a prior crashed run.
func StartCommandServer(socketPath string) error {
	cmdSrvMu.Lock()
	defer cmdSrvMu.Unlock()

	if cmdSrv.Load() != nil {
		return nil
	}
	if socketPath == "" {
		return errors.New("command socket path is empty")
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(socketPath) // stale leftover

	l, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	// Tighten permissions: only the App-Group sandbox can access it,
	// but be explicit anyway.
	_ = os.Chmod(socketPath, 0o600)

	gs := grpc.NewServer(
		grpc.MaxRecvMsgSize(controllerMaxMessageBytes),
		grpc.MaxSendMsgSize(controllerMaxMessageBytes),
	)
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

// StopCommandServer tears down the server. It first gives streams a
// short grace window to finish, then forces shutdown so a connected host
// app cannot keep the Network Extension stuck in stopTunnel.
func StopCommandServer() {
	cmdSrvMu.Lock()
	defer cmdSrvMu.Unlock()

	srv := cmdSrv.Swap(nil)
	if srv == nil {
		return
	}
	done := make(chan struct{})
	go func() {
		srv.grpcServer.GracefulStop()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(commandStopGrace):
		srv.grpcServer.Stop()
		<-done
	}
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

// SubscribeLogs forwards log events from mihomo's observable to the stream.
// The observable subscription is drained by a separate goroutine into a
// bounded latest-events queue. This is important on iOS: the host app can be
// suspended in the background while its Unix-socket gRPC stream stays open.
// If stream.Send blocked while also owning the observable subscription, a
// full subscriber buffer would eventually block mihomo's global logger.
//
// Every event is forwarded — there is no server-side level filter.
// mihomo's observable broadcasts every Debug/Info/Warning/Error
// regardless of the runtime log level, and the host (LogView) applies
// `selectedLevel` locally before display.
func (s *commandServiceImpl) SubscribeLogs(_ *pb.LogRequest, stream pb.Command_SubscribeLogsServer) error {
	sub := log.Subscribe()
	defer log.UnSubscribe(sub)

	events := make(chan stampedLogEvent, logStreamBuffer)
	go drainLogSubscription(stream.Context(), sub, events)

	for {
		select {
		case <-stream.Context().Done():
			return nil
		case event, ok := <-events:
			if !ok {
				return nil
			}
			err := stream.Send(&pb.LogMessage{
				Level:       int32(event.event.LogLevel),
				Payload:     event.event.Payload,
				TimestampNs: event.timestamp.UnixNano(),
			})
			if err != nil {
				return err
			}
		}
	}
}

// stampedLogEvent pairs a mihomo log.Event with the wall-clock time it
// was lifted off the observable. Stamping at drain time keeps the
// timestamp accurate even if stream.Send later spends time in
// backpressure: the host sees the time mihomo emitted the line, not the
// time the gRPC frame eventually flushed.
type stampedLogEvent struct {
	event     log.Event
	timestamp time.Time
}

func drainLogSubscription(ctx context.Context, sub <-chan log.Event, out chan stampedLogEvent) {
	defer close(out)
	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-sub:
			if !ok {
				return
			}
			enqueueLatestLogEvent(ctx, out, stampedLogEvent{event: event, timestamp: time.Now()})
		}
	}
}

func enqueueLatestLogEvent(ctx context.Context, out chan stampedLogEvent, event stampedLogEvent) {
	select {
	case out <- event:
		return
	default:
	}

	// Keep the newest events when a suspended host app is not draining its
	// gRPC stream. Dropping here is preferable to letting logging stall the
	// proxy core.
	select {
	case <-ctx.Done():
		return
	case <-out:
	default:
	}

	select {
	case <-ctx.Done():
	case out <- event:
	default:
	}
}

// Reload re-reads runtime_settings.json + the active profile YAML and
// hot-applies via hub.ApplyConfig. Errors come back to the host as
// gRPC status messages so the host UI can surface them verbatim.
//
// codes.FailedPrecondition is used for the "mihomo not started" case
// since that's a transient state on the host side (tunnel still
// connecting); codes.Internal covers parse / apply failures, where the
// message text carries the precise reason.
func (s *commandServiceImpl) Reload(_ context.Context, _ *pb.ReloadRequest) (*pb.ReloadResponse, error) {
	if err := Reload(); err != nil {
		if errors.Is(err, errMihomoNotStarted) {
			return nil, status.Error(codes.FailedPrecondition, err.Error())
		}
		return nil, status.Error(codes.Internal, err.Error())
	}
	return &pb.ReloadResponse{}, nil
}

// ControllerRequest executes a mihomo REST-controller request on behalf
// of the host app. The host talks to this command server over gRPC; the
// extension process then talks to mihomo's private Unix-domain controller
// socket using Go's standard net/http client. Keeping the Unix HTTP client
// in Go avoids a second hand-written HTTP parser in Swift while preserving
// mihomo's existing controller handlers.
func (s *commandServiceImpl) ControllerRequest(
	ctx context.Context,
	req *pb.ControllerRequestRequest,
) (*pb.ControllerRequestResponse, error) {
	resp, err := doControllerRequest(ctx, req)
	if err != nil {
		return nil, controllerStatusError(err)
	}
	return resp, nil
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

var controllerHTTPClient = &http.Client{
	Transport: &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			path := controllerSocketPath.Load()
			if path == "" {
				return nil, errControllerSocketUnconfigured
			}
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		},
	},
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

var (
	errControllerSocketUnconfigured = errors.New("controller socket path is not configured")
	errControllerResponseTooLarge   = errors.New("controller response exceeds IPC size limit")
)

func doControllerRequest(
	ctx context.Context,
	req *pb.ControllerRequestRequest,
) (*pb.ControllerRequestResponse, error) {
	method := strings.ToUpper(strings.TrimSpace(req.GetMethod()))
	if method == "" {
		return nil, status.Error(codes.InvalidArgument, "controller method is empty")
	}

	path := req.GetPath()
	if !strings.HasPrefix(path, "/") {
		return nil, status.Error(codes.InvalidArgument, "controller path must start with /")
	}
	u, err := url.ParseRequestURI(path)
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid controller path: %v", err)
	}
	u.Scheme = "http"
	u.Host = "unix"

	httpReq, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(req.GetBody()))
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "build controller request: %v", err)
	}
	httpReq.Host = "unix"
	httpReq.Header.Set("Accept", "*/*")
	if ct := strings.TrimSpace(req.GetContentType()); ct != "" {
		httpReq.Header.Set("Content-Type", ct)
	}

	httpResp, err := controllerHTTPClient.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer httpResp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(httpResp.Body, controllerMaxMessageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > controllerMaxMessageBytes {
		return nil, errControllerResponseTooLarge
	}
	return &pb.ControllerRequestResponse{
		Status: int32(httpResp.StatusCode),
		Body:   body,
	}, nil
}

func controllerStatusError(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := status.FromError(err); ok {
		return err
	}
	if errors.Is(err, errControllerSocketUnconfigured) || errors.Is(err, errMihomoNotStarted) {
		return status.Error(codes.FailedPrecondition, err.Error())
	}
	if errors.Is(err, errControllerResponseTooLarge) {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	if errors.Is(err, context.Canceled) {
		return status.Error(codes.Canceled, err.Error())
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return status.Error(codes.DeadlineExceeded, err.Error())
	}
	return status.Error(codes.Unavailable, err.Error())
}

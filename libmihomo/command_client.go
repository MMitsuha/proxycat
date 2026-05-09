package libmihomo

import (
	"context"
	"fmt"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	pb "github.com/proxycat/libmihomo/proto/command"
)

// CommandClientHandler is implemented in Swift via a gomobile-generated
// protocol. The runtime calls each method when the corresponding stream
// emits an event. None of these calls are allowed to block — Swift
// implementations should hop UI work to MainActor and return promptly.
//
// Lifecycle guarantees:
//   - Connected() fires exactly once per Connect() call, after the first
//     stream frame is received from the server (i.e. the socket is
//     actually live). It will not fire if the dial never succeeds.
//   - Disconnected() fires exactly once per Connect() call, when any
//     stream returns an error or Disconnect() is invoked.
type CommandClientHandler interface {
	Connected()
	Disconnected(message string)
	WriteStatus(status *Status)
	WriteLog(level int, payload string)
}

// CommandClientOptions selects which streams to subscribe to and how
// frequently the server should push status. Created from Swift via
// gomobile (no constructor required — zero value is "subscribe nothing").
type CommandClientOptions struct {
	SubscribeStatus  bool
	SubscribeLogs    bool
	StatusIntervalMs int64
}

// Status mirrors the gRPC StatusMessage but is the gomobile-friendly
// shape (no protobuf reflection / unexported fields). The client
// translates between the two when forwarding events.
type Status struct {
	Up             int64
	Down           int64
	UpTotal        int64
	DownTotal      int64
	Connections    int64
	MemoryResident int64
	MemoryBudget   int64
}

// CommandClient is the host-app-side counterpart to CommandServer.
type CommandClient struct {
	handler CommandClientHandler
	options *CommandClientOptions

	mu     sync.Mutex
	cancel context.CancelFunc
	conn   *grpc.ClientConn
	cli    pb.CommandClient
	wg     sync.WaitGroup

	connectOnce    sync.Once
	disconnectOnce sync.Once
}

// reloadTimeout caps how long Reload() waits before giving up.
// hub.ApplyConfig historically returns in well under 1s; a 30s ceiling
// surfaces a hung extension as a proper error rather than a UI freeze.
const reloadTimeout = 30 * time.Second

// setLogLevelTimeout caps how long SetLogLevel() waits. The handler is
// a single log.SetLevel call — no parsing, no I/O — so a short timeout
// is enough to distinguish "extension wedged" from "still propagating".
const setLogLevelTimeout = 5 * time.Second

// NewCommandClient builds a client. Call Connect to dial the socket and
// start streaming.
func NewCommandClient(handler CommandClientHandler, options *CommandClientOptions) *CommandClient {
	if options == nil {
		options = &CommandClientOptions{}
	}
	return &CommandClient{handler: handler, options: options}
}

// Connect dials the Unix-domain command socket and starts the requested
// streams. Returns an error if grpc.NewClient itself fails — note that
// this *won't* error when the socket isn't listening, since gRPC's
// non-blocking dial defers connection establishment to the first RPC.
// The caller learns about an unreachable server via Disconnected.
//
// Connected fires only after the first stream frame actually arrives,
// which is what callers should treat as "the extension is up".
func (c *CommandClient) Connect(socketPath string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		return nil
	}

	target := "unix://" + socketPath
	conn, err := grpc.NewClient(
		target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return fmt.Errorf("grpc dial %s: %w", target, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.conn = conn
	c.cancel = cancel
	cli := pb.NewCommandClient(conn)
	c.cli = cli

	subscribed := false
	if c.options.SubscribeStatus {
		c.wg.Add(1)
		stream, err := cli.SubscribeStatus(ctx, &pb.StatusRequest{IntervalMs: c.options.StatusIntervalMs})
		go runStream(c, stream, err, func(msg *pb.StatusMessage) {
			c.handler.WriteStatus(&Status{
				Up:             msg.Up,
				Down:           msg.Down,
				UpTotal:        msg.UpTotal,
				DownTotal:      msg.DownTotal,
				Connections:    msg.Connections,
				MemoryResident: msg.MemoryResident,
				MemoryBudget:   msg.MemoryBudget,
			})
		})
		subscribed = true
	}
	if c.options.SubscribeLogs {
		c.wg.Add(1)
		stream, err := cli.SubscribeLogs(ctx, &pb.LogRequest{})
		go runStream(c, stream, err, func(msg *pb.LogMessage) {
			c.handler.WriteLog(int(msg.Level), msg.Payload)
		})
		subscribed = true
	}
	// Pure plumbing client (neither stream subscribed): there's nothing
	// to wait on, treat it as connected immediately.
	if !subscribed {
		c.fireConnected()
	}
	return nil
}

// Disconnect terminates all streams and releases the gRPC connection.
// Safe to call multiple times. Blocks until both stream goroutines exit
// — call from a non-UI thread on the Swift side.
func (c *CommandClient) Disconnect() {
	c.mu.Lock()
	cancel := c.cancel
	conn := c.conn
	c.cancel = nil
	c.conn = nil
	c.cli = nil
	c.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if conn != nil {
		_ = conn.Close()
	}
	c.wg.Wait()
	// Make sure the disconnect callback fires even if both streams
	// already returned cleanly (or were never started).
	c.fireDisconnect(nil)
}

// runStream is the shared body of every server-streaming subscription:
// drain Recv into dispatch until the stream errors, signalling
// connected on the first frame and disconnected on any error or open
// failure. The stream type stays at the call site (gomobile-friendly
// proto types) and we constrain it via an inline interface so the
// generic compiles without listing every gRPC client interface.
//
// On any error we cancel the shared context before firing the
// disconnect callback. That stops the *other* stream goroutine from
// dispatching frames after the host has already moved on to a new
// reconnect cycle — which would surface as phantom traffic readings
// for one tick after every reconnect.
func runStream[Msg any](
	c *CommandClient,
	stream interface{ Recv() (*Msg, error) },
	openErr error,
	dispatch func(*Msg),
) {
	defer c.wg.Done()
	if openErr != nil {
		c.cancelContext()
		c.fireDisconnect(openErr)
		return
	}
	for {
		msg, err := stream.Recv()
		if err != nil {
			c.cancelContext()
			c.fireDisconnect(err)
			return
		}
		c.fireConnected()
		dispatch(msg)
	}
}

// cancelContext nudges every other stream goroutine sharing this
// client's context to exit the next time it returns from Recv. Idempotent.
func (c *CommandClient) cancelContext() {
	c.mu.Lock()
	cancel := c.cancel
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (c *CommandClient) fireConnected() {
	c.connectOnce.Do(func() {
		if c.handler != nil {
			c.handler.Connected()
		}
	})
}

func (c *CommandClient) fireDisconnect(err error) {
	c.disconnectOnce.Do(func() {
		if c.handler == nil {
			return
		}
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		c.handler.Disconnected(msg)
	})
}

// Reload tells the running mihomo core to re-read runtime_settings.json
// and the active profile YAML. Returns nil on success; on failure
// returns an error whose message is the gRPC status message produced
// by the server (e.g. "yaml: line 42: mapping values not allowed").
//
// Returns nil (not an error) when the connection isn't established:
// the Swift wrapper guards on its goClient before getting here, so a
// nil `c.cli` means the client raced with Disconnect between the
// guard and the gomobile call. runtime_settings.json is the source of
// truth — a missed nudge becomes a no-op, picked up on the next Start.
func (c *CommandClient) Reload() error {
	cli := c.client()
	if cli == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), reloadTimeout)
	defer cancel()
	if _, err := cli.Reload(ctx, &pb.ReloadRequest{}); err != nil {
		return fmt.Errorf("%s", grpcMessage(err))
	}
	return nil
}

// SetLogLevel pushes a runtime log filter into the extension's mihomo
// without triggering a hub.ApplyConfig. Levels: 0=DEBUG 1=INFO
// 2=WARNING 3=ERROR 4=SILENT (clamped on the server). Returns nil when
// the connection isn't established (same disconnect-race rationale as
// Reload).
func (c *CommandClient) SetLogLevel(level int) error {
	cli := c.client()
	if cli == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), setLogLevelTimeout)
	defer cancel()
	if _, err := cli.SetLogLevel(ctx, &pb.SetLogLevelRequest{Level: int32(level)}); err != nil {
		return fmt.Errorf("%s", grpcMessage(err))
	}
	return nil
}

func (c *CommandClient) client() pb.CommandClient {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cli
}

// grpcMessage strips the verbose `rpc error: code = X desc = ` prefix
// gRPC adds to status.Error() so the message we surface in the host UI
// is just the original Go error string ("mihomo not started",
// "yaml: line 42: ..."). The status code itself isn't useful to the
// user; the message is.
func grpcMessage(err error) string {
	if err == nil {
		return ""
	}
	if s, ok := status.FromError(err); ok {
		return s.Message()
	}
	return err.Error()
}

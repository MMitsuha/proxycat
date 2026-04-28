package libmihomo

import (
	"context"
	"fmt"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

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
	wg     sync.WaitGroup

	connectOnce    sync.Once
	disconnectOnce sync.Once
}

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

	subscribed := false
	if c.options.SubscribeStatus {
		c.wg.Add(1)
		go c.runStatus(ctx, cli)
		subscribed = true
	}
	if c.options.SubscribeLogs {
		c.wg.Add(1)
		go c.runLogs(ctx, cli)
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

func (c *CommandClient) runStatus(ctx context.Context, cli pb.CommandClient) {
	defer c.wg.Done()
	stream, err := cli.SubscribeStatus(ctx, &pb.StatusRequest{IntervalMs: c.options.StatusIntervalMs})
	if err != nil {
		c.fireDisconnect(err)
		return
	}
	for {
		msg, err := stream.Recv()
		if err != nil {
			c.fireDisconnect(err)
			return
		}
		c.fireConnected()
		c.handler.WriteStatus(&Status{
			Up:             msg.Up,
			Down:           msg.Down,
			UpTotal:        msg.UpTotal,
			DownTotal:      msg.DownTotal,
			Connections:    msg.Connections,
			MemoryResident: msg.MemoryResident,
			MemoryBudget:   msg.MemoryBudget,
		})
	}
}

func (c *CommandClient) runLogs(ctx context.Context, cli pb.CommandClient) {
	defer c.wg.Done()
	stream, err := cli.SubscribeLogs(ctx, &pb.LogRequest{})
	if err != nil {
		c.fireDisconnect(err)
		return
	}
	for {
		msg, err := stream.Recv()
		if err != nil {
			c.fireDisconnect(err)
			return
		}
		c.fireConnected()
		c.handler.WriteLog(int(msg.Level), msg.Payload)
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

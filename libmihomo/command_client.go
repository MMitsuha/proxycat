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
	SubscribeStatus    bool
	SubscribeLogs      bool
	StatusIntervalMs   int64
}

// Status mirrors the gRPC StatusMessage but is the gomobile-friendly
// shape (no protobuf reflection / unexported fields). The client
// translates between the two when forwarding events.
type Status struct {
	Up              int64
	Down            int64
	UpTotal         int64
	DownTotal       int64
	Connections     int64
	MemoryResident  int64
	MemoryBudget    int64
}

// CommandClient is the host-app-side counterpart to CommandServer.
type CommandClient struct {
	handler CommandClientHandler
	options *CommandClientOptions

	mu     sync.Mutex
	cancel context.CancelFunc
	conn   *grpc.ClientConn
	wg     sync.WaitGroup
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
// streams. Returns an error if the dial fails. Streams that fail later
// (e.g. extension restart) trigger the handler's Disconnected callback;
// callers can call Connect again to re-subscribe.
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

	if c.options.SubscribeStatus {
		c.wg.Add(1)
		go c.runStatus(ctx, cli)
	}
	if c.options.SubscribeLogs {
		c.wg.Add(1)
		go c.runLogs(ctx, cli)
	}
	if c.handler != nil {
		c.handler.Connected()
	}
	return nil
}

// Disconnect terminates all streams and releases the gRPC connection.
// Safe to call multiple times.
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
		c.handler.WriteLog(int(msg.Level), msg.Payload)
	}
}

func (c *CommandClient) fireDisconnect(err error) {
	if c.handler == nil {
		return
	}
	c.handler.Disconnected(err.Error())
}

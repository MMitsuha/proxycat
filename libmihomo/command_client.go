package libmihomo

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	pb "github.com/proxycat/libmihomo/proto/command"
)

// CommandClientDelegate is implemented in Swift via a gomobile-generated
// protocol. The runtime calls each method when the command IPC lifecycle
// changes or a subscribed stream emits a frame.
//
// Implementations must return promptly. Swift implementations should hop
// UI work to MainActor and avoid blocking Go stream goroutines.
//
// Lifecycle guarantees:
//   - OnConnected fires at most once per Connect call, after the first
//     stream frame arrives from the server. For clients with no streams
//     enabled it fires immediately after the gRPC client is created.
//   - OnDisconnected fires at most once per Connect call, when a stream
//     ends, an open fails, or Close/Disconnect is invoked.
type CommandClientDelegate interface {
	OnConnected()
	OnDisconnected(message string)
	OnStatus(status *CommandStatus)
	OnLog(level int, payload string)
}

// CommandClientConfig selects which command IPC streams to subscribe to and
// how frequently the server should push status frames. A nil config and the
// zero value both subscribe to nothing, which is useful for unary-only tests
// and tools.
type CommandClientConfig struct {
	SubscribeStatus  bool
	SubscribeLogs    bool
	StatusIntervalMs int64
}

type commandClientConfig struct {
	subscribeStatus  bool
	subscribeLogs    bool
	statusIntervalMs int64
}

func normalizeCommandClientConfig(config *CommandClientConfig) commandClientConfig {
	if config == nil {
		return commandClientConfig{}
	}
	return commandClientConfig{
		subscribeStatus:  config.SubscribeStatus,
		subscribeLogs:    config.SubscribeLogs,
		statusIntervalMs: config.StatusIntervalMs,
	}
}

// CommandStatus mirrors the gRPC StatusMessage but uses a gomobile-friendly
// shape with flat exported fields and no protobuf runtime state.
type CommandStatus struct {
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
	delegate CommandClientDelegate
	config   commandClientConfig

	mu      sync.Mutex
	session *commandClientSession
}

type commandClientSession struct {
	ctx      context.Context
	cancel   context.CancelFunc
	conn     *grpc.ClientConn
	client   pb.CommandClient
	delegate CommandClientDelegate

	wg           sync.WaitGroup
	connected    sync.Once
	disconnected sync.Once
	stopping     atomic.Bool
}

const (
	commandReloadTimeout      = 30 * time.Second
	commandSetLogLevelTimeout = 5 * time.Second
)

var commandConnectBackoff = backoff.Config{
	BaseDelay:  100 * time.Millisecond,
	Multiplier: 1.6,
	Jitter:     0.2,
	MaxDelay:   2 * time.Second,
}

// ControllerResponse is a gomobile-friendly copy of the ControllerRequest
// gRPC response.
type ControllerResponse struct {
	Status int
	Body   []byte
}

// NewCommandClient builds a client. Call Connect to dial the socket and start
// the configured streams.
func NewCommandClient(delegate CommandClientDelegate, config *CommandClientConfig) *CommandClient {
	return &CommandClient{
		delegate: delegate,
		config:   normalizeCommandClientConfig(config),
	}
}

// Connect creates the gRPC-over-Unix-socket client and starts the configured
// subscriptions. gRPC connection establishment is asynchronous; callers should
// treat OnConnected, not Connect returning nil, as the "extension is live"
// signal.
func (c *CommandClient) Connect(socketPath string) error {
	if socketPath == "" {
		return errors.New("command socket path is empty")
	}

	c.mu.Lock()
	if c.session != nil {
		c.mu.Unlock()
		return nil
	}

	target := commandSocketTarget(socketPath)
	conn, err := grpc.NewClient(
		target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithConnectParams(grpc.ConnectParams{
			Backoff:           commandConnectBackoff,
			MinConnectTimeout: time.Second,
		}),
		grpc.WithDefaultCallOptions(
			grpc.MaxCallRecvMsgSize(controllerMaxMessageBytes),
			grpc.MaxCallSendMsgSize(controllerMaxMessageBytes),
		),
	)
	if err != nil {
		c.mu.Unlock()
		return fmt.Errorf("grpc client %s: %w", target, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	session := &commandClientSession{
		ctx:      ctx,
		cancel:   cancel,
		conn:     conn,
		client:   pb.NewCommandClient(conn),
		delegate: c.delegate,
	}
	c.session = session
	config := c.config
	c.mu.Unlock()

	session.start(config)
	return nil
}

// Close terminates all streams and releases the gRPC connection. It is safe to
// call multiple times. Close blocks until stream goroutines exit, so Swift
// callers should invoke it away from the main actor.
func (c *CommandClient) Close() {
	c.mu.Lock()
	session := c.session
	c.session = nil
	c.mu.Unlock()

	if session != nil {
		session.close()
	}
}

// Disconnect is kept as a compatibility alias for older Swift call sites.
func (c *CommandClient) Disconnect() {
	c.Close()
}

func (s *commandClientSession) start(config commandClientConfig) {
	subscribed := false
	if config.subscribeStatus {
		s.wg.Add(1)
		stream, err := s.client.SubscribeStatus(s.ctx, &pb.StatusRequest{
			IntervalMs: config.statusIntervalMs,
		})
		go runCommandStream(s, stream, err, func(msg *pb.StatusMessage) {
			if s.delegate == nil {
				return
			}
			s.delegate.OnStatus(&CommandStatus{
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
	if config.subscribeLogs {
		s.wg.Add(1)
		stream, err := s.client.SubscribeLogs(s.ctx, &pb.LogRequest{})
		go runCommandStream(s, stream, err, func(msg *pb.LogMessage) {
			if s.delegate != nil {
				s.delegate.OnLog(int(msg.Level), msg.Payload)
			}
		})
		subscribed = true
	}
	if !subscribed {
		s.fireConnected()
	}
}

func (s *commandClientSession) close() {
	s.stopping.Store(true)
	s.cancel()
	if s.conn != nil {
		_ = s.conn.Close()
	}
	s.wg.Wait()
	s.fireDisconnected(nil)
}

// runCommandStream is the shared body for every server-streaming subscription.
// It marks the IPC as connected after the first frame, dispatches every frame
// to Swift, and turns any stream end into one disconnection event.
func runCommandStream[Msg any](
	s *commandClientSession,
	stream interface{ Recv() (*Msg, error) },
	openErr error,
	dispatch func(*Msg),
) {
	defer s.wg.Done()
	if openErr != nil {
		s.finish(openErr)
		return
	}
	for {
		msg, err := stream.Recv()
		if err != nil {
			s.finish(err)
			return
		}
		s.fireConnected()
		dispatch(msg)
	}
}

func (s *commandClientSession) finish(err error) {
	s.cancel()
	s.fireDisconnected(s.disconnectError(err))
}

func (s *commandClientSession) disconnectError(err error) error {
	if err == nil || s.stopping.Load() || errors.Is(err, context.Canceled) {
		return nil
	}
	if st, ok := status.FromError(err); ok && st.Code() == codes.Canceled {
		return nil
	}
	return err
}

func (s *commandClientSession) fireConnected() {
	s.connected.Do(func() {
		if s.delegate != nil {
			s.delegate.OnConnected()
		}
	})
}

func (s *commandClientSession) fireDisconnected(err error) {
	s.disconnected.Do(func() {
		if s.delegate == nil {
			return
		}
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		s.delegate.OnDisconnected(msg)
	})
}

// Reload tells the running mihomo core to re-read runtime_settings.json and the
// active profile YAML. Returns nil when the connection is not currently open;
// the on-disk settings remain the source of truth and will be picked up on the
// next tunnel start.
func (c *CommandClient) Reload() error {
	cli := c.grpcClient()
	if cli == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), commandReloadTimeout)
	defer cancel()
	if _, err := cli.Reload(ctx, &pb.ReloadRequest{}); err != nil {
		return fmt.Errorf("%s", grpcMessage(err))
	}
	return nil
}

// SetLogLevel is a legacy diagnostic hook for changing mihomo's own logrus
// print level. The current Logs tab filters locally and does not call this.
func (c *CommandClient) SetLogLevel(level int) error {
	cli := c.grpcClient()
	if cli == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), commandSetLogLevelTimeout)
	defer cancel()
	if _, err := cli.SetLogLevel(ctx, &pb.SetLogLevelRequest{Level: int32(level)}); err != nil {
		return fmt.Errorf("%s", grpcMessage(err))
	}
	return nil
}

// ControllerRequest forwards one native-controller HTTP request through
// the command server. `path` is an absolute, already-escaped request
// target (`/proxies`, `/connections/{id}`, `/group/{name}/delay?...`).
func (c *CommandClient) ControllerRequest(
	method string,
	path string,
	contentType string,
	body []byte,
	timeoutMs int64,
) (*ControllerResponse, error) {
	cli := c.grpcClient()
	if cli == nil {
		return nil, errors.New("command IPC is not connected")
	}
	if timeoutMs <= 0 {
		timeoutMs = 5000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	resp, err := cli.ControllerRequest(ctx, &pb.ControllerRequestRequest{
		Method:      method,
		Path:        path,
		ContentType: contentType,
		Body:        body,
	})
	if err != nil {
		return nil, fmt.Errorf("%s", grpcMessage(err))
	}
	return &ControllerResponse{
		Status: int(resp.GetStatus()),
		Body:   resp.GetBody(),
	}, nil
}

func (c *CommandClient) grpcClient() pb.CommandClient {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.session == nil {
		return nil
	}
	return c.session.client
}

func commandSocketTarget(socketPath string) string {
	return "unix://" + socketPath
}

// grpcMessage strips the verbose "rpc error: code = X desc =" prefix gRPC adds
// to status.Error so the host UI can show the original Go error text.
func grpcMessage(err error) string {
	if err == nil {
		return ""
	}
	if s, ok := status.FromError(err); ok {
		return s.Message()
	}
	return err.Error()
}

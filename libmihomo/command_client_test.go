package libmihomo

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

type commandClientTestDelegate struct {
	connected    chan struct{}
	disconnected chan string
	status       chan *CommandStatus
}

func newCommandClientTestDelegate() *commandClientTestDelegate {
	return &commandClientTestDelegate{
		connected:    make(chan struct{}, 1),
		disconnected: make(chan string, 1),
		status:       make(chan *CommandStatus, 1),
	}
}

func (d *commandClientTestDelegate) OnConnected() {
	select {
	case d.connected <- struct{}{}:
	default:
	}
}

func (d *commandClientTestDelegate) OnDisconnected(message string) {
	select {
	case d.disconnected <- message:
	default:
	}
}

func (d *commandClientTestDelegate) OnStatus(status *CommandStatus) {
	select {
	case d.status <- status:
	default:
	}
}

func (d *commandClientTestDelegate) OnLog(int, string, int64) {}

func TestCommandClientStreamsStatusAndCloses(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "pcmd-")
	if err != nil {
		t.Fatalf("create temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	socketPath := filepath.Join(dir, "command.sock")
	if err := StartCommandServer(socketPath); err != nil {
		t.Fatalf("start command server: %v", err)
	}
	t.Cleanup(StopCommandServer)

	delegate := newCommandClientTestDelegate()
	client := NewCommandClient(delegate, &CommandClientConfig{
		SubscribeStatus:  true,
		StatusIntervalMs: 10,
	})
	if err := client.Connect(socketPath); err != nil {
		t.Fatalf("connect command client: %v", err)
	}
	t.Cleanup(client.Close)

	select {
	case <-delegate.connected:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for connected callback")
	}

	select {
	case status := <-delegate.status:
		if status == nil {
			t.Fatal("status callback received nil status")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for status callback")
	}

	client.Close()
	select {
	case message := <-delegate.disconnected:
		if message != "" {
			t.Fatalf("disconnect message = %q, want empty", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for disconnected callback")
	}
}

func TestCommandClientRejectsEmptySocketPath(t *testing.T) {
	client := NewCommandClient(nil, nil)
	if err := client.Connect(""); err == nil {
		t.Fatal("Connect empty socket path succeeded")
	}
}

func TestCommandClientReportsMissingSocket(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "pcmd-missing-")
	if err != nil {
		t.Fatalf("create temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	delegate := newCommandClientTestDelegate()
	client := NewCommandClient(delegate, &CommandClientConfig{
		SubscribeStatus:  true,
		StatusIntervalMs: 10,
	})
	if err := client.Connect(filepath.Join(dir, "missing.sock")); err != nil {
		t.Fatalf("connect missing socket: %v", err)
	}
	t.Cleanup(client.Close)

	select {
	case <-delegate.connected:
		t.Fatal("connected callback fired for missing socket")
	case message := <-delegate.disconnected:
		if message == "" {
			t.Fatal("missing socket disconnected with empty message")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for missing-socket disconnect callback")
	}
}

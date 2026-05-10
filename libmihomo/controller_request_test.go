package libmihomo

import (
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "github.com/proxycat/libmihomo/proto/command"
)

func TestControllerRequestUsesUnixHTTPAndPreservesEscapedPath(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "pctl-")
	if err != nil {
		t.Fatalf("create temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	socketPath := filepath.Join(dir, "controller.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	server := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPut {
				t.Errorf("method = %s, want PUT", r.Method)
			}
			if got := r.URL.EscapedPath(); got != "/proxies/JP%2FTokyo" {
				t.Errorf("escaped path = %q, want /proxies/JP%%2FTokyo", got)
			}
			if got := r.Header.Get("Content-Type"); got != "application/json" {
				t.Errorf("content-type = %q, want application/json", got)
			}
			body, err := io.ReadAll(r.Body)
			if err != nil {
				t.Errorf("read body: %v", err)
			}
			if string(body) != `{"name":"node"}` {
				t.Errorf("body = %q", body)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"ok":true}`))
		}),
	}
	go func() {
		_ = server.Serve(listener)
	}()
	t.Cleanup(func() {
		_ = server.Close()
		controllerSocketPath.Store("")
	})

	controllerSocketPath.Store(socketPath)
	resp, err := doControllerRequest(context.Background(), &pb.ControllerRequestRequest{
		Method:      "put",
		Path:        "/proxies/JP%2FTokyo",
		ContentType: "application/json",
		Body:        []byte(`{"name":"node"}`),
	})
	if err != nil {
		t.Fatalf("controller request: %v", err)
	}
	if resp.GetStatus() != http.StatusCreated {
		t.Fatalf("status = %d, want 201", resp.GetStatus())
	}
	if string(resp.GetBody()) != `{"ok":true}` {
		t.Fatalf("body = %q, want {\"ok\":true}", resp.GetBody())
	}
}

func TestControllerRequestRejectsRelativePath(t *testing.T) {
	_, err := doControllerRequest(context.Background(), &pb.ControllerRequestRequest{
		Method: "GET",
		Path:   "proxies",
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("status.Code(err) = %s, want InvalidArgument; err=%v", status.Code(err), err)
	}
}

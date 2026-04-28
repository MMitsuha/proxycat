//go:build tools

// This file pins golang.org/x/mobile/bind as a direct module dependency so
// that `gomobile bind` can import it. Without this, `go mod tidy` prunes
// x/mobile (since no normal source file references bind), and gobind then
// fails with "unable to import bind: no Go package in golang.org/x/mobile/bind".
package tools

import (
	_ "golang.org/x/mobile/bind"
)

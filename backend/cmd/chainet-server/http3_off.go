//go:build !http3

package main

import (
	"context"
	"errors"
	"net/http"
)

// http3Available is false in the default (dependency-free) build. Build with -tags http3.
const http3Available = false

func serveHTTP3(ctx context.Context, addr, cert, key string, h http.Handler) error {
	return errors.New("built without HTTP/3 support; rebuild with -tags http3")
}

//go:build http3

package main

import (
	"context"
	"net/http"

	"github.com/quic-go/quic-go/http3"
)

// http3Available enables HTTP/3 (QUIC) on the HTTPS address (UDP) when TLS is configured.
const http3Available = true

func serveHTTP3(ctx context.Context, addr, cert, key string, h http.Handler) error {
	srv := &http3.Server{Addr: addr, Handler: h}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	return srv.ListenAndServeTLS(cert, key)
}

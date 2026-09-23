// Command chainet-server runs the ChaiNet measurement backend:
//
//	/ping /download /upload /health /info over HTTP/1.1 + h2c, HTTPS (HTTP/2, optional HTTP/3)
//	and a UDP echo for packet-loss / jitter tests.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/kongdean2374/chainet/backend/internal/server"
)

func main() {
	d := server.Defaults()
	cfg := d
	flag.StringVar(&cfg.Name, "name", env("CHAINET_NAME", d.Name), "server display name")
	flag.StringVar(&cfg.Location, "location", env("CHAINET_LOCATION", d.Location), "server location label")
	flag.StringVar(&cfg.HTTPAddr, "http", env("CHAINET_HTTP", d.HTTPAddr), "HTTP/1.1 + h2c listen address (empty = off)")
	flag.StringVar(&cfg.HTTPSAddr, "https", env("CHAINET_HTTPS", ""), "HTTPS listen address, e.g. [::]:8443 (needs -cert/-key)")
	flag.StringVar(&cfg.CertFile, "cert", env("CHAINET_CERT", ""), "TLS certificate (PEM)")
	flag.StringVar(&cfg.KeyFile, "key", env("CHAINET_KEY", ""), "TLS private key (PEM)")
	flag.StringVar(&cfg.UDPEchoAddr, "udp", env("CHAINET_UDP", d.UDPEchoAddr), "UDP echo listen address (empty = off)")
	flag.IntVar(&cfg.UDPEchoPort, "udp-advertise-port", envInt("CHAINET_UDP_PORT", d.UDPEchoPort), "UDP echo port advertised in /info")
	flag.Int64Var(&cfg.MaxDownloadBytes, "max-download", int64(envInt("CHAINET_MAX_DOWNLOAD", int(d.MaxDownloadBytes))), "max bytes per /download")
	flag.Int64Var(&cfg.MaxUploadBytes, "max-upload", int64(envInt("CHAINET_MAX_UPLOAD", int(d.MaxUploadBytes))), "max bytes per /upload")
	flag.DurationVar(&cfg.MaxRequestDuration, "max-duration", d.MaxRequestDuration, "max duration of one transfer")
	flag.Float64Var(&cfg.RequestsPerSecond, "rps", d.RequestsPerSecond, "requests per second per client IP")
	flag.Float64Var(&cfg.Burst, "burst", d.Burst, "request burst per client IP")
	flag.IntVar(&cfg.MaxSessionsPerIP, "sessions-per-ip", d.MaxSessionsPerIP, "concurrent transfers per client IP")
	flag.IntVar(&cfg.MaxSessionsTotal, "sessions-total", d.MaxSessionsTotal, "concurrent transfers in total")
	flag.Float64Var(&cfg.UDPPacketsPerSecond, "udp-pps", d.UDPPacketsPerSecond, "UDP echo packets per second per source")
	flag.BoolVar(&cfg.TrustProxyHeaders, "trust-proxy", false, "use X-Forwarded-For (only behind a trusted reverse proxy)")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := server.New(cfg, log)
	tlsEnabled := cfg.HTTPSAddr != "" && cfg.CertFile != "" && cfg.KeyFile != ""
	if tlsEnabled && http3Available {
		srv.SetHTTP3Enabled(true)
	}
	handler := srv.Handler()
	go srv.Sweep(ctx)

	var servers []*http.Server
	errs := make(chan error, 4)

	if cfg.HTTPAddr != "" {
		protocols := new(http.Protocols)
		protocols.SetHTTP1(true)
		protocols.SetUnencryptedHTTP2(true) // h2c for clients that support prior knowledge
		hs := &http.Server{Addr: cfg.HTTPAddr, Handler: handler, Protocols: protocols, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
		servers = append(servers, hs)
		go func() {
			log.Info("http listening", "addr", cfg.HTTPAddr)
			errs <- hs.ListenAndServe()
		}()
	}
	if tlsEnabled {
		hs := &http.Server{Addr: cfg.HTTPSAddr, Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second,
			TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, NextProtos: []string{"h2", "http/1.1"}}}
		servers = append(servers, hs)
		go func() {
			log.Info("https listening (HTTP/2)", "addr", cfg.HTTPSAddr)
			errs <- hs.ListenAndServeTLS(cfg.CertFile, cfg.KeyFile)
		}()
		if http3Available {
			go func() {
				log.Info("http/3 listening (QUIC)", "addr", cfg.HTTPSAddr)
				errs <- serveHTTP3(ctx, cfg.HTTPSAddr, cfg.CertFile, cfg.KeyFile, handler)
			}()
		}
	}
	if cfg.UDPEchoAddr != "" {
		echo, err := server.ListenUDPEcho(cfg.UDPEchoAddr, cfg, log)
		if err != nil {
			log.Error("udp echo", "err", err)
			os.Exit(1)
		}
		go func() {
			log.Info("udp echo listening", "addr", echo.Addr().String())
			errs <- echo.Serve(ctx)
		}()
	}

	select {
	case <-ctx.Done():
	case err := <-errs:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listener failed", "err", err)
		}
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, hs := range servers {
		_ = hs.Shutdown(shutdown)
	}
	log.Info("stopped")
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v, ok := os.LookupEnv(key); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

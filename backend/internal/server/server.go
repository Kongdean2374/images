package server

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Server is the HTTP measurement API.
type Server struct {
	cfg      Config
	limiter  *RateLimiter
	sessions *SessionLimiter
	started  time.Time
	payload  []byte
	log      *slog.Logger
	requests atomic.Int64
}

// New builds a server with defaults applied.
func New(cfg Config, logger *slog.Logger) *Server {
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.Default()
	}
	// 1 MiB of random bytes, repeated for downloads: incompressible, no per-request RNG cost.
	payload := make([]byte, 1<<20)
	if _, err := rand.Read(payload); err != nil {
		panic(err)
	}
	return &Server{
		cfg:      cfg,
		limiter:  NewRateLimiter(cfg.RequestsPerSecond, cfg.Burst, nil),
		sessions: NewSessionLimiter(cfg.MaxSessionsPerIP, cfg.MaxSessionsTotal),
		started:  time.Now(),
		payload:  payload,
		log:      logger,
	}
}

// Config returns the effective configuration.
func (s *Server) Config() Config { return s.cfg }

// SetHTTP3Enabled records that an HTTP/3 listener is running (advertised in /info and Alt-Svc).
func (s *Server) SetHTTP3Enabled(on bool) { s.cfg.HTTP3Enabled = on }

// Handler returns the routed, rate-limited handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ping", s.handlePing)
	mux.HandleFunc("HEAD /ping", s.handlePing)
	mux.HandleFunc("GET /download", s.handleDownload)
	mux.HandleFunc("POST /upload", s.handleUpload)
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /info", s.handleInfo)
	return s.middleware(mux)
}

// Sweep periodically drops idle rate-limit buckets until ctx is done.
func (s *Server) Sweep(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.limiter.Sweep(5 * time.Minute)
		}
	}
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.requests.Add(1)
		h := w.Header()
		h.Set("Cache-Control", "no-store, no-transform")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Timing-Allow-Origin", "*")
		if s.cfg.HTTP3Enabled && r.TLS != nil {
			if _, port, err := net.SplitHostPort(s.cfg.HTTPSAddr); err == nil {
				h.Set("Alt-Svc", `h3=":`+port+`"; ma=86400`)
			}
		}
		if !s.limiter.Allow(s.clientIP(r)) {
			h.Set("Retry-After", "1")
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// clientIP returns the caller's IP (without port).
func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxyHeaders {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			return strings.TrimSpace(strings.Split(xff, ",")[0])
		}
		if xr := r.Header.Get("X-Real-IP"); xr != "" {
			return strings.TrimSpace(xr)
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func ipFamily(ip string) string {
	parsed := net.ParseIP(ip)
	switch {
	case parsed == nil:
		return "unknown"
	case parsed.To4() != nil:
		return "ipv4"
	default:
		return "ipv6"
	}
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	if seq := r.URL.Query().Get("seq"); seq != "" && len(seq) <= 16 {
		w.Header().Set("X-Seq", seq)
	}
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = io.WriteString(w, "pong")
	}
}

// handleDownload streams ?bytes=N random bytes (capped at MaxDownloadBytes, bounded in time).
func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	n, err := strconv.ParseInt(r.URL.Query().Get("bytes"), 10, 64)
	if err != nil || n < 0 {
		http.Error(w, "bytes must be a non-negative integer", http.StatusBadRequest)
		return
	}
	if n > s.cfg.MaxDownloadBytes {
		n = s.cfg.MaxDownloadBytes
	}
	release, ok := s.sessions.Acquire(s.clientIP(r))
	if !ok {
		w.Header().Set("Retry-After", "2")
		http.Error(w, "too many concurrent sessions", http.StatusServiceUnavailable)
		return
	}
	defer release()

	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.MaxRequestDuration)
	defer cancel()
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Now().Add(s.cfg.MaxRequestDuration))

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(n, 10))
	w.WriteHeader(http.StatusOK)
	remaining := n
	for remaining > 0 {
		if ctx.Err() != nil {
			return // client gone or max duration reached; connection is closed mid-body
		}
		chunk := int64(len(s.payload))
		if remaining < chunk {
			chunk = remaining
		}
		if _, err := w.Write(s.payload[:chunk]); err != nil {
			return
		}
		remaining -= chunk
	}
}

type uploadReply struct {
	Bytes      int64   `json:"bytes"`
	DurationMs float64 `json:"duration_ms"`
	Truncated  bool    `json:"truncated"`
}

// handleUpload reads and discards the body (max MaxUploadBytes, bounded in time).
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.ContentLength > s.cfg.MaxUploadBytes {
		http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
		return
	}
	release, ok := s.sessions.Acquire(s.clientIP(r))
	if !ok {
		w.Header().Set("Retry-After", "2")
		http.Error(w, "too many concurrent sessions", http.StatusServiceUnavailable)
		return
	}
	defer release()

	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(s.cfg.MaxRequestDuration))
	body := http.MaxBytesReader(w, r.Body, s.cfg.MaxUploadBytes)
	start := time.Now()
	n, err := io.Copy(io.Discard, body)
	reply := uploadReply{Bytes: n, DurationMs: float64(time.Since(start).Microseconds()) / 1000}
	var maxErr *http.MaxBytesError
	switch {
	case errors.As(err, &maxErr):
		http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
		return
	case err != nil:
		// Deadline hit or client aborted: report what arrived.
		reply.Truncated = true
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(reply)
}

type healthReply struct {
	Status         string  `json:"status"`
	ActiveSessions int     `json:"active_sessions"`
	UptimeSeconds  float64 `json:"uptime_seconds"`
	Requests       int64   `json:"requests"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	status := "ok"
	if s.sessions.Active() >= s.cfg.MaxSessionsTotal {
		status = "saturated"
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(healthReply{
		Status: status, ActiveSessions: s.sessions.Active(),
		UptimeSeconds: time.Since(s.started).Seconds(), Requests: s.requests.Load(),
	})
}

// InfoReply matches ServerInfo in the iOS app (snake_case keys).
type InfoReply struct {
	Name                   string `json:"name"`
	Location               string `json:"location"`
	Version                string `json:"version"`
	ClientIP               string `json:"client_ip"`
	ClientIPFamily         string `json:"client_ip_family"`
	HTTPProtocol           string `json:"http_protocol"`
	SupportsHTTP3          bool   `json:"supports_http3"`
	UDPEchoPort            *int   `json:"udp_echo_port,omitempty"`
	MaxDownloadBytes       int64  `json:"max_download_bytes"`
	MaxUploadBytes         int64  `json:"max_upload_bytes"`
	MaxTestDurationSeconds int    `json:"max_test_duration_seconds"`
}

func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	reply := InfoReply{
		Name: s.cfg.Name, Location: s.cfg.Location, Version: s.cfg.Version,
		ClientIP: ip, ClientIPFamily: ipFamily(ip), HTTPProtocol: r.Proto, SupportsHTTP3: s.cfg.HTTP3Enabled,
		MaxDownloadBytes: s.cfg.MaxDownloadBytes, MaxUploadBytes: s.cfg.MaxUploadBytes,
		MaxTestDurationSeconds: int(s.cfg.MaxRequestDuration.Seconds()),
	}
	if s.cfg.UDPEchoAddr != "" && s.cfg.UDPEchoPort > 0 {
		p := s.cfg.UDPEchoPort
		reply.UDPEchoPort = &p
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(reply)
}

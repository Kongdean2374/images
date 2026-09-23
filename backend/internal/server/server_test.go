package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T, mutate func(*Config)) (*Server, *httptest.Server) {
	t.Helper()
	cfg := Defaults()
	cfg.RequestsPerSecond = 1000
	cfg.Burst = 1000
	if mutate != nil {
		mutate(&cfg)
	}
	s := New(cfg, nil)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func TestPing(t *testing.T) {
	_, ts := newTestServer(t, nil)
	resp, err := http.Get(ts.URL + "/ping?seq=7")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "pong" || resp.Header.Get("X-Seq") != "7" {
		t.Fatalf("unexpected ping reply %d %q %q", resp.StatusCode, body, resp.Header.Get("X-Seq"))
	}
	if !strings.Contains(resp.Header.Get("Cache-Control"), "no-store") {
		t.Fatal("responses must not be cacheable")
	}
}

func TestDownloadExactBytesAndCap(t *testing.T) {
	_, ts := newTestServer(t, func(c *Config) { c.MaxDownloadBytes = 3 << 20 })
	for _, tc := range []struct {
		ask, want int64
	}{{0, 0}, {1234, 1234}, {2<<20 + 5, 2<<20 + 5}, {10 << 20, 3 << 20}} {
		resp, err := http.Get(ts.URL + "/download?bytes=" + itoa(tc.ask))
		if err != nil {
			t.Fatal(err)
		}
		n, _ := io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if n != tc.want {
			t.Fatalf("asked %d: got %d bytes, want %d", tc.ask, n, tc.want)
		}
	}
}

func TestDownloadRejectsBadInput(t *testing.T) {
	_, ts := newTestServer(t, nil)
	for _, q := range []string{"", "bytes=-1", "bytes=abc"} {
		resp, _ := http.Get(ts.URL + "/download?" + q)
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("%q: status %d", q, resp.StatusCode)
		}
	}
}

func TestDownloadPayloadIsNotTrivial(t *testing.T) {
	_, ts := newTestServer(t, nil)
	resp, _ := http.Get(ts.URL + "/download?bytes=4096")
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if bytes.Count(b, []byte{0}) > 200 {
		t.Fatal("payload should be random, not zeros (compression would inflate results)")
	}
}

func TestUploadDiscardsAndReports(t *testing.T) {
	_, ts := newTestServer(t, nil)
	resp, err := http.Post(ts.URL+"/upload", "application/octet-stream", bytes.NewReader(make([]byte, 500_000)))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var r uploadReply
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		t.Fatal(err)
	}
	if r.Bytes != 500_000 {
		t.Fatalf("bytes %d", r.Bytes)
	}
}

func TestUploadPayloadLimit(t *testing.T) {
	_, ts := newTestServer(t, func(c *Config) { c.MaxUploadBytes = 1000 })
	resp, _ := http.Post(ts.URL+"/upload", "application/octet-stream", bytes.NewReader(make([]byte, 5000)))
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status %d", resp.StatusCode)
	}
	// Chunked (unknown length) bodies are cut off by MaxBytesReader.
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/upload", io.NopCloser(bytes.NewReader(make([]byte, 5000))))
	req.ContentLength = -1
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("chunked status %d", resp.StatusCode)
	}
}

func TestMethodRouting(t *testing.T) {
	_, ts := newTestServer(t, nil)
	resp, _ := http.Post(ts.URL+"/download?bytes=1", "text/plain", nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestRateLimit(t *testing.T) {
	_, ts := newTestServer(t, func(c *Config) { c.RequestsPerSecond = 1; c.Burst = 3 })
	codes := map[int]int{}
	for i := 0; i < 6; i++ {
		resp, _ := http.Get(ts.URL + "/ping")
		resp.Body.Close()
		codes[resp.StatusCode]++
	}
	if codes[http.StatusOK] < 3 || codes[http.StatusTooManyRequests] < 2 {
		t.Fatalf("unexpected codes %v", codes)
	}
}

func TestConcurrentSessionLimit(t *testing.T) {
	s, ts := newTestServer(t, func(c *Config) { c.MaxSessionsPerIP = 1 })
	release, ok := s.sessions.Acquire("127.0.0.1")
	if !ok {
		t.Fatal("first slot")
	}
	resp, _ := http.Get(ts.URL + "/download?bytes=10")
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status %d", resp.StatusCode)
	}
	release()
	resp, _ = http.Get(ts.URL + "/download?bytes=10")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("after release status %d", resp.StatusCode)
	}
}

func TestMaxDurationStopsDownload(t *testing.T) {
	_, ts := newTestServer(t, func(c *Config) { c.MaxRequestDuration = 200 * time.Millisecond; c.MaxDownloadBytes = 1 << 40 })
	resp, err := http.Get(ts.URL + "/download?bytes=1099511627776")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	// Read slowly so the server hits its deadline.
	buf := make([]byte, 1<<16)
	for {
		if _, err := resp.Body.Read(buf); err != nil {
			break
		}
		if time.Since(start) > 10*time.Second {
			t.Fatal("download was not bounded in time")
		}
	}
	resp.Body.Close()
}

func TestInfoAndHealth(t *testing.T) {
	_, ts := newTestServer(t, func(c *Config) { c.Name = "Taipei-1"; c.Location = "Taipei" })
	resp, _ := http.Get(ts.URL + "/info")
	var info map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	for _, k := range []string{"name", "location", "version", "client_ip", "client_ip_family", "http_protocol", "supports_http3",
		"udp_echo_port", "max_download_bytes", "max_upload_bytes", "max_test_duration_seconds"} {
		if _, ok := info[k]; !ok {
			t.Fatalf("missing %s in %v", k, info)
		}
	}
	if info["client_ip_family"] != "ipv4" || info["name"] != "Taipei-1" {
		t.Fatalf("info %v", info)
	}
	resp, _ = http.Get(ts.URL + "/health")
	var h healthReply
	_ = json.NewDecoder(resp.Body).Decode(&h)
	resp.Body.Close()
	if h.Status != "ok" {
		t.Fatalf("health %+v", h)
	}
}

func TestIPv6Listener(t *testing.T) {
	ln, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skip("IPv6 loopback unavailable:", err)
	}
	s := New(Defaults(), nil)
	hs := &http.Server{Handler: s.Handler()}
	go hs.Serve(ln)
	defer hs.Close()
	resp, err := http.Get("http://" + ln.Addr().String() + "/info")
	if err != nil {
		t.Fatal(err)
	}
	var info InfoReply
	_ = json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info.ClientIPFamily != "ipv6" {
		t.Fatalf("family %q", info.ClientIPFamily)
	}
}

func TestTrustProxyHeaders(t *testing.T) {
	s := New(Config{TrustProxyHeaders: true}, nil)
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("X-Forwarded-For", "2001:db8::1, 10.0.0.1")
	if got := s.clientIP(r); got != "2001:db8::1" {
		t.Fatal(got)
	}
	s2 := New(Config{}, nil)
	if got := s2.clientIP(r); got == "2001:db8::1" {
		t.Fatal("proxy headers must be ignored unless trusted")
	}
}

func TestTokenBucket(t *testing.T) {
	now := time.Unix(0, 0)
	l := NewRateLimiter(2, 2, func() time.Time { return now })
	if !l.Allow("a") || !l.Allow("a") || l.Allow("a") {
		t.Fatal("burst of 2")
	}
	now = now.Add(500 * time.Millisecond) // +1 token at 2/s
	if !l.Allow("a") || l.Allow("a") {
		t.Fatal("refill")
	}
	if !l.Allow("b") {
		t.Fatal("keys are independent")
	}
	now = now.Add(time.Hour)
	l.Sweep(time.Minute)
	if l.Len() != 0 {
		t.Fatal("sweep")
	}
}

func TestUDPEcho(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	echo, err := ListenUDPEcho("127.0.0.1:0", Defaults(), nil)
	if err != nil {
		t.Fatal(err)
	}
	go echo.Serve(ctx)
	conn, err := net.Dial("udp", echo.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))

	packet := append([]byte("CHNT"), 0, 0, 0, 42)
	packet = append(packet, make([]byte, 56)...)
	if _, err := conn.Write(packet); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 2048)
	n, err := conn.Read(buf)
	if err != nil || !bytes.Equal(buf[:n], packet) {
		t.Fatalf("echo mismatch: %v", err)
	}

	// Non-ChaiNet datagrams are dropped (no reflection).
	_, _ = conn.Write([]byte("GET / HTTP/1.1"))
	_ = conn.SetDeadline(time.Now().Add(300 * time.Millisecond))
	if _, err := conn.Read(buf); err == nil {
		t.Fatal("foreign packet must not be echoed")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

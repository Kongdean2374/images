// Package server implements the ChaiNet measurement backend.
package server

import "time"

// Config holds every limit and listener setting. Zero values are replaced by Defaults().
type Config struct {
	Name     string
	Location string
	Version  string

	// HTTPAddr serves HTTP/1.1 and cleartext HTTP/2 (h2c). "[::]:8080" listens on IPv4 and IPv6.
	HTTPAddr string
	// HTTPSAddr serves TLS with HTTP/2 (and HTTP/3 over QUIC when built with -tags http3).
	HTTPSAddr string
	CertFile  string
	KeyFile   string
	// UDPEchoAddr serves the UDP echo used for packet-loss / jitter / gaming tests.
	UDPEchoAddr string
	// UDPEchoPort is advertised in /info (may differ from the bound port behind NAT).
	UDPEchoPort int

	// MaxDownloadBytes caps one /download response.
	MaxDownloadBytes int64
	// MaxUploadBytes caps one /upload request body.
	MaxUploadBytes int64
	// MaxRequestDuration bounds one /download or /upload transfer.
	MaxRequestDuration time.Duration

	// RequestsPerSecond / Burst: token bucket per client IP for all endpoints.
	RequestsPerSecond float64
	Burst             float64
	// MaxSessionsPerIP / MaxSessionsTotal: concurrent /download + /upload transfers.
	MaxSessionsPerIP int
	MaxSessionsTotal int

	// UDPPacketsPerSecond / UDPBurst: token bucket per source address for UDP echo.
	UDPPacketsPerSecond float64
	UDPBurst            float64
	// UDPMaxPayload drops larger datagrams (no fragmentation-based abuse).
	UDPMaxPayload int

	// TrustProxyHeaders uses X-Forwarded-For / X-Real-IP for the client IP (only behind a trusted proxy).
	TrustProxyHeaders bool

	// HTTP3Enabled is set at runtime when the http3 build tag is compiled in and TLS is configured.
	HTTP3Enabled bool
}

// Defaults returns production-sane limits.
func Defaults() Config {
	return Config{
		Name:                "ChaiNet Server",
		Location:            "Unknown",
		Version:             "1.0.0",
		HTTPAddr:            "[::]:8080",
		UDPEchoAddr:         "[::]:9001",
		UDPEchoPort:         9001,
		MaxDownloadBytes:    1 << 30,  // 1 GiB
		MaxUploadBytes:      256 << 20, // 256 MiB
		MaxRequestDuration:  60 * time.Second,
		RequestsPerSecond:   50,
		Burst:               100,
		MaxSessionsPerIP:    24,
		MaxSessionsTotal:    512,
		UDPPacketsPerSecond: 250,
		UDPBurst:            500,
		UDPMaxPayload:       1472,
	}
}

func (c Config) withDefaults() Config {
	d := Defaults()
	if c.Name == "" {
		c.Name = d.Name
	}
	if c.Location == "" {
		c.Location = d.Location
	}
	if c.Version == "" {
		c.Version = d.Version
	}
	if c.MaxDownloadBytes <= 0 {
		c.MaxDownloadBytes = d.MaxDownloadBytes
	}
	if c.MaxUploadBytes <= 0 {
		c.MaxUploadBytes = d.MaxUploadBytes
	}
	if c.MaxRequestDuration <= 0 {
		c.MaxRequestDuration = d.MaxRequestDuration
	}
	if c.RequestsPerSecond <= 0 {
		c.RequestsPerSecond = d.RequestsPerSecond
	}
	if c.Burst <= 0 {
		c.Burst = d.Burst
	}
	if c.MaxSessionsPerIP <= 0 {
		c.MaxSessionsPerIP = d.MaxSessionsPerIP
	}
	if c.MaxSessionsTotal <= 0 {
		c.MaxSessionsTotal = d.MaxSessionsTotal
	}
	if c.UDPPacketsPerSecond <= 0 {
		c.UDPPacketsPerSecond = d.UDPPacketsPerSecond
	}
	if c.UDPBurst <= 0 {
		c.UDPBurst = d.UDPBurst
	}
	if c.UDPMaxPayload <= 0 {
		c.UDPMaxPayload = d.UDPMaxPayload
	}
	return c
}

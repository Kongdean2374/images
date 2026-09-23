package server

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net"
	"time"
)

// Magic prefix of ChaiNet UDP echo packets. Other datagrams are dropped, so the echo can't be
// used to reflect arbitrary traffic, and replies are never larger than requests (no amplification).
var Magic = []byte("CHNT")

// UDPEcho echoes ChaiNet probe packets back to the sender, rate-limited per source address.
type UDPEcho struct {
	conn    net.PacketConn
	limiter *RateLimiter
	maxSize int
	log     *slog.Logger
}

// ListenUDPEcho binds addr ("[::]:9001" serves IPv4 and IPv6).
func ListenUDPEcho(addr string, cfg Config, logger *slog.Logger) (*UDPEcho, error) {
	cfg = cfg.withDefaults()
	conn, err := net.ListenPacket("udp", addr)
	if err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &UDPEcho{conn: conn, limiter: NewRateLimiter(cfg.UDPPacketsPerSecond, cfg.UDPBurst, nil), maxSize: cfg.UDPMaxPayload, log: logger}, nil
}

// Addr is the bound address.
func (u *UDPEcho) Addr() net.Addr { return u.conn.LocalAddr() }

// Serve runs until ctx is cancelled.
func (u *UDPEcho) Serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		_ = u.conn.Close()
	}()
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				u.limiter.Sweep(5 * time.Minute)
			}
		}
	}()
	buf := make([]byte, 65535)
	for {
		n, addr, err := u.conn.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			u.log.Warn("udp read", "err", err)
			continue
		}
		if n < 8 || n > u.maxSize || !bytes.Equal(buf[:4], Magic) {
			continue
		}
		host := addr.String()
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if !u.limiter.Allow(host) {
			continue
		}
		if _, err := u.conn.WriteTo(buf[:n], addr); err != nil {
			u.log.Debug("udp write", "err", err)
		}
	}
}

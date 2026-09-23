package server

import (
	"sync"
	"time"
)

// TokenBucket is a classic token bucket:
//
//	tokens = min(burst, tokens + (now − last) × rate); allow ⇔ tokens ≥ 1, then tokens −= 1
type TokenBucket struct {
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
}

func newBucket(rate, burst float64, now time.Time) *TokenBucket {
	return &TokenBucket{rate: rate, burst: burst, tokens: burst, last: now}
}

func (b *TokenBucket) allow(now time.Time) bool {
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
		b.last = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// RateLimiter keeps one bucket per key (client IP) and evicts idle buckets.
type RateLimiter struct {
	mu      sync.Mutex
	rate    float64
	burst   float64
	buckets map[string]*TokenBucket
	now     func() time.Time
}

// NewRateLimiter creates a limiter; now may be nil (time.Now).
func NewRateLimiter(rate, burst float64, now func() time.Time) *RateLimiter {
	if now == nil {
		now = time.Now
	}
	return &RateLimiter{rate: rate, burst: burst, buckets: map[string]*TokenBucket{}, now: now}
}

// Allow consumes one token for key.
func (l *RateLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		b = newBucket(l.rate, l.burst, now)
		l.buckets[key] = b
	}
	return b.allow(now)
}

// Sweep removes buckets idle longer than maxIdle (they would be full anyway).
func (l *RateLimiter) Sweep(maxIdle time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := l.now().Add(-maxIdle)
	for k, b := range l.buckets {
		if b.last.Before(cutoff) {
			delete(l.buckets, k)
		}
	}
}

// Len is the number of tracked keys (tests / metrics).
func (l *RateLimiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}

// SessionLimiter bounds concurrent transfers per key and globally.
type SessionLimiter struct {
	mu       sync.Mutex
	perKey   int
	total    int
	active   map[string]int
	inFlight int
}

func NewSessionLimiter(perKey, total int) *SessionLimiter {
	return &SessionLimiter{perKey: perKey, total: total, active: map[string]int{}}
}

// Acquire reserves a slot; the returned release func must be called exactly once.
func (s *SessionLimiter) Acquire(key string) (release func(), ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inFlight >= s.total || s.active[key] >= s.perKey {
		return nil, false
	}
	s.inFlight++
	s.active[key]++
	var once sync.Once
	return func() {
		once.Do(func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.inFlight--
			s.active[key]--
			if s.active[key] <= 0 {
				delete(s.active, key)
			}
		})
	}, true
}

// Active is the number of in-flight transfers.
func (s *SessionLimiter) Active() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.inFlight
}

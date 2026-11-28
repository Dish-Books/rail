package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The runner's HTTP listener, on loopback in the sandbox: what a command
// reaches Rail's Claude proxy and MCP server through. Each request is one
// channel: the runner opens it with the request line and headers, sends the
// body on stream 0 and eof; Rail answers with head, the body on stream 0, and
// close.
const (
	headWait = 10 * time.Minute
	// Claude's requests carry a conversation, images and all.
	maxRequestBody = 64 << 20
)

// The headers a request keeps on its way to Rail. Everything else, cookies and
// hop-by-hop headers included, stays in the sandbox.
var forwardedHeaders = map[string]bool{
	"accept":                   true,
	"anthropic-beta":           true,
	"anthropic-version":        true,
	"authorization":            true,
	"content-type":             true,
	"mcp-protocol-version":     true,
	"mcp-session-id":           true,
	"user-agent":               true,
	"x-app":                    true,
	"x-claude-code-session-id": true,
	"x-stainless-retry-count":  true,
	"x-stainless-timeout":      true,
}

func (d *daemon) listenHTTP() (net.Listener, error) {
	addr := d.cfg.HTTPAddr
	if addr == "" {
		addr = "127.0.0.1:0"
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	d.mu.Lock()
	d.httpURL = "http://" + ln.Addr().String()
	d.mu.Unlock()
	return ln, nil
}

func (d *daemon) serveHTTP(ln net.Listener) {
	srv := &http.Server{Handler: http.HandlerFunc(d.handleHTTP), ReadHeaderTimeout: 30 * time.Second}
	_ = srv.Serve(ln)
}

func (d *daemon) localURL() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.httpURL
}

// claudeToken makes the credential one process gives the Claude proxy. It
// names that process to the runner and is worth nothing outside the sandbox.
func claudeToken() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "rail-sandbox-" + hex.EncodeToString(b), nil
}

func (d *daemon) registerToken(token string, id json.RawMessage) {
	if token == "" {
		return
	}
	d.mu.Lock()
	d.tokens[token] = id
	d.mu.Unlock()
}

func (d *daemon) forgetToken(token string) {
	if token == "" {
		return
	}
	d.mu.Lock()
	delete(d.tokens, token)
	d.mu.Unlock()
}

// tokenProc is the process a request's bearer names, or nil.
func (d *daemon) tokenProc(r *http.Request) json.RawMessage {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		token = r.Header.Get("X-Api-Key")
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.tokens[token]
}

func (d *daemon) handleHTTP(w http.ResponseWriter, r *http.Request) {
	var kind string
	var procID json.RawMessage
	switch {
	case strings.HasPrefix(r.URL.Path, "/v1/"):
		kind = "claude"
		if procID = d.tokenProc(r); procID == nil {
			httpError(w, http.StatusUnauthorized, "authentication_error", "this sandbox gave no Claude credential to this caller")
			return
		}
	case r.URL.Path == "/mcp" || strings.HasPrefix(r.URL.Path, "/mcp/"):
		kind = "mcp"
	default:
		httpError(w, http.StatusNotFound, "not_found_error", "rail-runner serves /v1/ and /mcp only")
		return
	}

	s := d.waitSession(sessionWait)
	if s == nil {
		httpError(w, http.StatusBadGateway, "api_error", "rail-runner is not connected to Rail")
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		select {
		case <-s.ctx.Done():
			cancel()
		case <-ctx.Done():
		}
	}()

	headers := map[string][]string{}
	for k, v := range r.Header {
		if forwardedHeaders[strings.ToLower(k)] {
			headers[strings.ToLower(k)] = v
		}
	}
	_, c := s.openChannel(func(n uint32) channel {
		return &httpChan{s: s, ch: n, ctx: ctx, cancel: cancel, out: newFlow(0), notify: make(chan struct{}, 1)}
	})
	h := c.(*httpChan)
	defer s.unregister(h.ch, h)
	open := openMsg{T: "open", Ch: h.ch, Kind: kind, Proc: procID, Method: r.Method, Path: r.URL.RequestURI(), Headers: headers}
	if err := s.sendJSON(open); err != nil {
		httpError(w, http.StatusBadGateway, "api_error", "rail-runner lost Rail")
		return
	}

	go h.sendBody(http.MaxBytesReader(w, r.Body, maxRequestBody))
	h.respond(w)
}

func httpError(w http.ResponseWriter, status int, kind, message string) {
	b, _ := json.Marshal(map[string]any{"type": "error", "error": map[string]string{"type": kind, "message": message}})
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.WriteHeader(status)
	_, _ = w.Write(b)
}

// httpChan is one request to Rail and its response.
type httpChan struct {
	s      *session
	ch     uint32
	ctx    context.Context
	cancel context.CancelFunc
	out    *flow // the request body we send

	mu     sync.Mutex
	head   *inMsg
	recv   uint64
	q      [][]byte
	closed bool
	err    string
	notify chan struct{}
}

func (h *httpChan) wake() {
	select {
	case h.notify <- struct{}{}:
	default:
	}
}

func (h *httpChan) onHead(m inMsg) {
	h.mu.Lock()
	if h.head == nil {
		h.head = &m
	}
	h.mu.Unlock()
	h.wake()
}

func (h *httpChan) onData(stream uint8, off uint64, p []byte) {
	if stream != 0 {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	end := off + uint64(len(p))
	switch {
	case end <= h.recv:
		return
	case off > h.recv:
		h.closed, h.err = true, "missing bytes"
		h.wake()
		return
	}
	h.q = append(h.q, append([]byte(nil), p[h.recv-off:]...))
	h.recv = end
	h.wake()
}

func (h *httpChan) onAck(stream uint8, off uint64) {
	if stream == 0 {
		h.out.ack(off)
	}
}

func (h *httpChan) onEOF(uint8) {}

func (h *httpChan) onClose(m inMsg) {
	h.mu.Lock()
	h.closed = true
	h.err = m.Error
	h.mu.Unlock()
	h.wake()
}

func (h *httpChan) stop() { h.cancel() }

func (h *httpChan) sendBody(r io.Reader) {
	var sent uint64
	buf := make([]byte, maxFramePayload)
	for {
		room, err := h.out.room(h.ctx, sent, h.s.window.Load())
		if err != nil {
			return
		}
		n, err := r.Read(buf[:room])
		if n > 0 {
			if serr := h.s.sendFrame(h.ctx, h.ch, 0, sent, buf[:n]); serr != nil {
				return
			}
			sent += uint64(n)
		}
		if errors.Is(err, io.EOF) {
			_ = h.s.sendJSON(eofMsg{T: "eof", Ch: h.ch, Stream: 0})
			return
		}
		if err != nil {
			_ = h.s.sendJSON(closeMsg{T: "close", Ch: h.ch, Error: "the request body could not be read: " + err.Error()})
			h.cancel()
			return
		}
	}
}

// respond writes Rail's answer as it arrives, flushing each part so a
// stream reaches its reader as Rail sends it, and acking what it wrote.
func (h *httpChan) respond(w http.ResponseWriter) {
	flusher, _ := w.(http.Flusher)
	deadline := time.NewTimer(headWait)
	defer deadline.Stop()
	headSent := false
	var written, acked uint64
	window := uint64(h.s.window.Load())
	for {
		h.mu.Lock()
		head, q, closed, errText := h.head, h.q, h.closed, h.err
		h.q = nil
		h.mu.Unlock()

		if !headSent && head != nil {
			for k, v := range head.Headers {
				for _, value := range v {
					w.Header().Add(k, value)
				}
			}
			status := head.Status
			if status == 0 {
				status = http.StatusBadGateway
			}
			w.WriteHeader(status)
			headSent = true
		}
		if headSent {
			for _, p := range q {
				if _, err := w.Write(p); err != nil {
					_ = h.s.sendJSON(closeMsg{T: "close", Ch: h.ch, Error: "the caller went away"})
					return
				}
				written += uint64(len(p))
			}
			if len(q) > 0 {
				if flusher != nil {
					flusher.Flush()
				}
				if written-acked >= window/4 || closed {
					acked = written
					_ = h.s.sendJSON(ackMsg{T: "ack", Ch: h.ch, Stream: 0, Offset: acked})
				}
				continue
			}
			if written > acked {
				acked = written
				_ = h.s.sendJSON(ackMsg{T: "ack", Ch: h.ch, Stream: 0, Offset: acked})
			}
		}
		if closed {
			if !headSent {
				if errText == "" {
					errText = "Rail closed the request without answering it"
				}
				httpError(w, http.StatusBadGateway, "api_error", errText)
			}
			return
		}
		select {
		case <-h.notify:
		case <-h.ctx.Done():
			if !headSent {
				httpError(w, http.StatusBadGateway, "api_error", "rail-runner lost Rail")
			}
			_ = h.s.sendJSON(closeMsg{T: "close", Ch: h.ch, Error: "the caller went away"})
			return
		case <-deadline.C:
			if !headSent {
				_ = h.s.sendJSON(closeMsg{T: "close", Ch: h.ch, Error: "no answer in time"})
				httpError(w, http.StatusGatewayTimeout, "api_error", "Rail did not answer in time")
				return
			}
		}
	}
}

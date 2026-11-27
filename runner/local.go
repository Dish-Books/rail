package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

// The unix socket at $RAIL_RUNNER_STATE/runner.sock: a shim sends one JSON
// line, then bytes.
type localReq struct {
	Kind    string `json:"kind"`
	Service string `json:"service"`
	Payload string `json:"payload"`
}

type signReply struct {
	Signature string `json:"signature,omitempty"`
	Error     string `json:"error,omitempty"`
}

const (
	sessionWait = 30 * time.Second
	signTimeout = 2 * time.Minute
)

func (d *daemon) serveLocal(c *net.UnixConn) {
	br := bufio.NewReader(c)
	line, err := br.ReadBytes('\n')
	if err != nil {
		c.Close()
		return
	}
	var req localReq
	if err := json.Unmarshal(line, &req); err != nil {
		writeJSONLine(c, signReply{Error: "bad request: " + err.Error()})
		c.Close()
		return
	}
	switch req.Kind {
	case "git":
		d.serveGit(c, br, req.Service)
	case "sign":
		d.serveSign(c, req.Payload)
	default:
		writeJSONLine(c, signReply{Error: "unknown kind " + req.Kind})
		c.Close()
	}
}

func writeJSONLine(w io.Writer, v any) {
	b, _ := json.Marshal(v)
	_, _ = w.Write(append(b, '\n'))
}

func (d *daemon) serveSign(c net.Conn, payload string) {
	defer c.Close()
	if _, err := base64.StdEncoding.DecodeString(payload); err != nil {
		writeJSONLine(c, signReply{Error: "payload is not base64"})
		return
	}
	s := d.waitSession(sessionWait)
	if s == nil {
		writeJSONLine(c, signReply{Error: "rail-runner is not connected to Rail"})
		return
	}
	sig, err := s.sign(payload, signTimeout)
	if err != nil {
		writeJSONLine(c, signReply{Error: err.Error()})
		return
	}
	writeJSONLine(c, signReply{Signature: sig})
}

func (d *daemon) serveGit(c *net.UnixConn, br *bufio.Reader, service string) {
	if service != "git-upload-pack" && service != "git-receive-pack" {
		d.log.Printf("git: unsupported service %q", service)
		c.Close()
		return
	}
	s := d.waitSession(sessionWait)
	if s == nil {
		d.log.Printf("git: not connected to Rail")
		c.Close()
		return
	}
	ctx, cancel := context.WithCancel(s.ctx)
	_, ch := s.openChannel(func(n uint32) channel {
		return &gitChan{s: s, ch: n, conn: c, ctx: ctx, cancel: cancel, out: newFlow(0), notify: make(chan struct{}, 1)}
	})
	g := ch.(*gitChan)
	if err := s.sendJSON(openMsg{T: "open", Ch: g.ch, Kind: "git", Service: service}); err != nil {
		g.stop()
		return
	}
	go g.toLocal()
	go g.toRail(br)
	go func() {
		<-ctx.Done()
		c.Close()
		s.unregister(g.ch, g)
	}()
}

// gitChan bridges a git-remote-rail connection to stream 0 of a channel.
type gitChan struct {
	s      *session
	ch     uint32
	conn   *net.UnixConn
	ctx    context.Context
	cancel context.CancelFunc
	out    *flow // what we send to Rail

	mu     sync.Mutex
	recv   uint64   // bytes received from Rail
	q      [][]byte // received, not yet written to conn
	eof    bool
	closed bool
	notify chan struct{}
}

func (g *gitChan) wake() {
	select {
	case g.notify <- struct{}{}:
	default:
	}
}

func (g *gitChan) onData(stream uint8, off uint64, p []byte) {
	if stream != 0 {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.eof || g.closed {
		return
	}
	end := off + uint64(len(p))
	switch {
	case end <= g.recv:
		return // a frame sent again
	case off > g.recv:
		// A gap: bytes went missing. The stream can't be trusted.
		g.closed = true
		go func() {
			_ = g.s.sendJSON(closeMsg{T: "close", Ch: g.ch, Error: "missing bytes"})
			g.cancel()
		}()
		return
	}
	p = p[g.recv-off:]
	g.q = append(g.q, append([]byte(nil), p...))
	g.recv = end
	g.wake()
}

func (g *gitChan) onAck(stream uint8, off uint64) {
	if stream == 0 {
		g.out.ack(off)
	}
}

func (g *gitChan) onEOF(stream uint8) {
	if stream != 0 {
		return
	}
	g.mu.Lock()
	g.eof = true
	g.mu.Unlock()
	g.wake()
}

// onClose ends the channel once what Rail sent before it is written out.
func (g *gitChan) onClose(inMsg) {
	g.mu.Lock()
	g.closed = true
	g.mu.Unlock()
	g.wake()
}

func (g *gitChan) stop() { g.cancel() }

// toLocal writes what Rail sends to the shim, acking as it goes.
func (g *gitChan) toLocal() {
	var written, acked uint64
	window := uint64(g.s.window.Load())
	halfClosed := false
	for {
		g.mu.Lock()
		q := g.q
		g.q = nil
		eof, closed := g.eof, g.closed
		g.mu.Unlock()

		for _, p := range q {
			if _, err := g.conn.Write(p); err != nil {
				_ = g.s.sendJSON(closeMsg{T: "close", Ch: g.ch, Error: "git-remote-rail went away"})
				g.cancel()
				return
			}
			written += uint64(len(p))
			if written-acked >= window/4 {
				acked = written
				_ = g.s.sendJSON(ackMsg{T: "ack", Ch: g.ch, Stream: 0, Offset: acked})
			}
		}
		if len(q) > 0 && written > acked {
			acked = written
			_ = g.s.sendJSON(ackMsg{T: "ack", Ch: g.ch, Stream: 0, Offset: acked})
		}
		if len(q) > 0 {
			continue
		}
		if eof && !halfClosed {
			halfClosed = true
			_ = g.conn.CloseWrite()
		}
		if closed {
			g.cancel()
			return
		}
		select {
		case <-g.notify:
		case <-g.ctx.Done():
			return
		}
	}
}

// toRail sends what the shim writes, within the window, then eof.
func (g *gitChan) toRail(r io.Reader) {
	var sent uint64
	buf := make([]byte, maxFramePayload)
	for {
		room, err := g.out.room(g.ctx, sent, g.s.window.Load())
		if err != nil {
			return
		}
		n, err := r.Read(buf[:room])
		if n > 0 {
			if serr := g.s.sendFrame(g.ctx, g.ch, 0, sent, buf[:n]); serr != nil {
				return
			}
			sent += uint64(n)
		}
		if errors.Is(err, io.EOF) {
			_ = g.s.sendJSON(eofMsg{T: "eof", Ch: g.ch, Stream: 0})
			return
		}
		if err != nil {
			if g.ctx.Err() == nil {
				_ = g.s.sendJSON(closeMsg{T: "close", Ch: g.ch, Error: "git-remote-rail went away"})
				g.cancel()
			}
			return
		}
	}
}

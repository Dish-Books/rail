package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeRail is an in-process Rail that speaks docs/sandbox-socket.md: it
// welcomes, serves git channels from a real bare repo with git upload-pack
// and receive-pack, signs with a throwaway key, and hands everything else to
// the test as events.
type fakeRail struct {
	t      *testing.T
	srv    *httptest.Server
	token  string
	window int64
	pingMs int64
	bare   string // the task's repo, for git channels
	key    string // private key file, for sign

	conns chan *fakeConn
}

type msg map[string]any

func (m msg) str(k string) string { s, _ := m[k].(string); return s }
func (m msg) num(k string) int64 {
	f, _ := m[k].(float64)
	return int64(f)
}

type frame struct {
	ch     uint32
	stream uint8
	off    uint64
	data   []byte
}

// event is one message from the runner that the fake didn't handle itself,
// in the order it came.
type event struct {
	msg   msg
	frame *frame
}

type fakeConn struct {
	r      *fakeRail
	c      *websocket.Conn
	header http.Header
	hello  msg
	ctx    context.Context

	wmu     sync.Mutex
	events  chan event
	replies chan msg

	gmu  sync.Mutex
	gits map[uint32]*fakeGit
}

func newFakeRail(t *testing.T) *fakeRail {
	r := &fakeRail{t: t, token: "test-token", window: defaultWindow, pingMs: defaultPingMs, conns: make(chan *fakeConn, 16)}
	r.srv = httptest.NewServer(http.HandlerFunc(r.serve))
	t.Cleanup(r.srv.Close)
	return r
}

func (r *fakeRail) url() string {
	return "ws" + strings.TrimPrefix(r.srv.URL, "http") + "/sandbox/socket"
}

func (r *fakeRail) serve(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/sandbox/socket" {
		http.NotFound(w, req)
		return
	}
	if req.Header.Get("X-Rail-Sandbox-Token") != r.token {
		http.Error(w, "unknown token", http.StatusForbidden)
		return
	}
	c, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(256 << 20)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fc := &fakeConn{
		r: r, c: c, header: req.Header.Clone(), ctx: ctx,
		events: make(chan event, 100_000), replies: make(chan msg, 100),
		gits: map[uint32]*fakeGit{},
	}
	defer fc.closeGits()
	for {
		typ, b, err := c.Read(ctx)
		if err != nil {
			close(fc.events)
			return
		}
		if typ == websocket.MessageBinary {
			ch, stream, off, data, err := decodeFrame(b)
			if err != nil {
				r.t.Errorf("fake: bad frame: %v", err)
				continue
			}
			if g := fc.git(ch); g != nil {
				g.fromRunner(off, data)
				continue
			}
			fc.events <- event{frame: &frame{ch, stream, off, append([]byte(nil), data...)}}
			continue
		}
		var m msg
		if err := json.Unmarshal(b, &m); err != nil {
			r.t.Errorf("fake: bad message %s: %v", b, err)
			continue
		}
		switch t := m.str("t"); {
		case t == "hello":
			fc.hello = m
			fc.send(msg{"t": "welcome", "window": r.window, "ping_ms": r.pingMs})
			r.conns <- fc
		case t == "open" && m.str("kind") == "git":
			fc.openGit(m)
		case t == "sign":
			go fc.sign(m)
		case t == "reply":
			fc.replies <- m
		case (t == "ack" || t == "eof" || t == "close") && fc.git(uint32(m.num("ch"))) != nil:
			fc.git(uint32(m.num("ch"))).control(m)
		default:
			fc.events <- event{msg: m}
		}
	}
}

// next waits for the runner's next connection.
func (r *fakeRail) next(t *testing.T) *fakeConn {
	t.Helper()
	select {
	case fc := <-r.conns:
		return fc
	case <-time.After(10 * time.Second):
		t.Fatal("runner did not connect")
		return nil
	}
}

func (fc *fakeConn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	fc.wmu.Lock()
	defer fc.wmu.Unlock()
	_ = fc.c.Write(fc.ctx, websocket.MessageText, b)
}

func (fc *fakeConn) sendFrame(ch uint32, stream uint8, off uint64, data []byte) {
	fc.wmu.Lock()
	defer fc.wmu.Unlock()
	_ = fc.c.Write(fc.ctx, websocket.MessageBinary, encodeFrame(ch, stream, off, data))
}

// drop cuts the connection without a close handshake, as a network would.
func (fc *fakeConn) drop() { fc.c.CloseNow() }

func (fc *fakeConn) next(t *testing.T) event {
	t.Helper()
	select {
	case e, ok := <-fc.events:
		if !ok {
			t.Fatal("connection closed")
		}
		return e
	case <-time.After(20 * time.Second):
		t.Fatal("timed out waiting for the runner")
		return event{}
	}
}

// waitMsg skips events until a message of type typ.
func (fc *fakeConn) waitMsg(t *testing.T, typ string) msg {
	t.Helper()
	for {
		e := fc.next(t)
		if e.msg != nil && e.msg.str("t") == typ {
			return e.msg
		}
	}
}

var callSeq struct {
	sync.Mutex
	n int
}

// call sends a call and waits for its reply.
func (fc *fakeConn) call(t *testing.T, method string, params any) msg {
	t.Helper()
	callSeq.Lock()
	callSeq.n++
	id := fmt.Sprintf("call-%d", callSeq.n)
	callSeq.Unlock()
	fc.send(msg{"t": "call", "id": id, "method": method, "params": params})
	select {
	case m := <-fc.replies:
		if m.str("id") != id {
			t.Fatalf("reply for %v, want %s", m["id"], id)
		}
		return m
	case <-time.After(60 * time.Second):
		t.Fatalf("no reply to %s", method)
		return nil
	}
}

func (fc *fakeConn) callOK(t *testing.T, method string, params any) map[string]any {
	t.Helper()
	m := fc.call(t, method, params)
	if ok, _ := m["ok"].(bool); !ok {
		t.Fatalf("%s failed: %v", method, m["error"])
	}
	res, _ := m["result"].(map[string]any)
	return res
}

func (fc *fakeConn) sign(m msg) {
	payload, err := base64.StdEncoding.DecodeString(m.str("payload"))
	reply := msg{"t": "signed", "id": m["id"]}
	if err == nil {
		var sig []byte
		sig, err = sshSign(fc.r.key, payload)
		reply["signature"] = string(sig)
	}
	if err != nil {
		delete(reply, "signature")
		reply["error"] = err.Error()
	}
	fc.send(reply)
}

func sshSign(key string, payload []byte) ([]byte, error) {
	dir, err := os.MkdirTemp("", "fake-sign")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	f := filepath.Join(dir, "payload")
	if err := os.WriteFile(f, payload, 0o600); err != nil {
		return nil, err
	}
	out, err := exec.Command("ssh-keygen", "-Y", "sign", "-n", "git", "-f", key, f).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("ssh-keygen: %v: %s", err, out)
	}
	return os.ReadFile(f + ".sig")
}

// fakeGit serves one git channel with git upload-pack or receive-pack.
type fakeGit struct {
	fc  *fakeConn
	ch  uint32
	cmd *exec.Cmd

	mu     sync.Mutex
	cond   *sync.Cond
	in     [][]byte // for the process's stdin
	inEOF  bool
	recv   uint64
	acked  uint64 // how far the runner acked what we sent
	closed bool
}

func (fc *fakeConn) git(ch uint32) *fakeGit {
	fc.gmu.Lock()
	defer fc.gmu.Unlock()
	return fc.gits[ch]
}

func (fc *fakeConn) closeGits() {
	fc.gmu.Lock()
	defer fc.gmu.Unlock()
	for _, g := range fc.gits {
		g.mu.Lock()
		g.closed = true
		g.cond.Broadcast()
		g.mu.Unlock()
		if g.cmd.Process != nil {
			g.cmd.Process.Kill()
		}
	}
}

func (fc *fakeConn) openGit(m msg) {
	ch := uint32(m.num("ch"))
	if ch%2 != 0 {
		fc.r.t.Errorf("runner opened odd channel %d", ch)
	}
	service := m.str("service")
	if service != "git-upload-pack" && service != "git-receive-pack" {
		fc.send(msg{"t": "close", "ch": ch, "error": "bad service"})
		return
	}
	g := &fakeGit{fc: fc, ch: ch}
	g.cond = sync.NewCond(&g.mu)
	g.cmd = exec.Command("git", strings.TrimPrefix(service, "git-"), fc.r.bare)
	stdin, _ := g.cmd.StdinPipe()
	stdout, _ := g.cmd.StdoutPipe()
	g.cmd.Stderr = os.Stderr
	if err := g.cmd.Start(); err != nil {
		fc.send(msg{"t": "close", "ch": ch, "error": err.Error()})
		return
	}
	fc.gmu.Lock()
	fc.gits[ch] = g
	fc.gmu.Unlock()
	go g.pumpIn(stdin)
	go g.pumpOut(stdout)
}

func (g *fakeGit) fromRunner(off uint64, data []byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if off != g.recv {
		g.fc.r.t.Errorf("git channel %d: frame at %d, expected %d", g.ch, off, g.recv)
		return
	}
	g.recv += uint64(len(data))
	g.in = append(g.in, append([]byte(nil), data...))
	g.cond.Broadcast()
}

func (g *fakeGit) control(m msg) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch m.str("t") {
	case "ack":
		if off := uint64(m.num("offset")); off > g.acked {
			g.acked = off
		}
	case "eof":
		g.inEOF = true
	case "close":
		g.closed = true
		if g.cmd.Process != nil {
			g.cmd.Process.Kill()
		}
	}
	g.cond.Broadcast()
}

// pumpIn feeds the process what the runner sends, acking once written.
func (g *fakeGit) pumpIn(w io.WriteCloser) {
	defer w.Close()
	for {
		g.mu.Lock()
		for len(g.in) == 0 && !g.inEOF && !g.closed {
			g.cond.Wait()
		}
		in := g.in
		g.in = nil
		eof, closed := g.inEOF, g.closed
		recv := g.recv
		g.mu.Unlock()
		if closed {
			return
		}
		for _, p := range in {
			if _, err := w.Write(p); err != nil {
				return
			}
		}
		if len(in) > 0 {
			g.fc.send(msg{"t": "ack", "ch": g.ch, "stream": 0, "offset": recv})
		}
		if eof && len(in) == 0 {
			return
		}
	}
}

// pumpOut sends the process's output within the window, then eof and close.
func (g *fakeGit) pumpOut(r io.Reader) {
	var sent uint64
	buf := make([]byte, maxFramePayload)
	for {
		g.mu.Lock()
		for sent-g.acked >= uint64(g.fc.r.window) && !g.closed {
			g.cond.Wait()
		}
		room := min(uint64(g.fc.r.window)-(sent-g.acked), maxFramePayload)
		closed := g.closed
		g.mu.Unlock()
		if closed {
			return
		}
		n, err := r.Read(buf[:room])
		if n > 0 {
			g.fc.sendFrame(g.ch, 0, sent, buf[:n])
			sent += uint64(n)
		}
		if err != nil {
			break
		}
	}
	err := g.cmd.Wait()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	}
	g.fc.send(msg{"t": "eof", "ch": g.ch, "stream": 0})
	g.fc.send(msg{"t": "close", "ch": g.ch, "code": code})
	g.fc.gmu.Lock()
	delete(g.fc.gits, g.ch)
	g.fc.gmu.Unlock()
}

// procResult is what a proc channel carried.
type procResult struct {
	started msg
	out     []byte
	err     []byte
	exit    msg
	eofs    int
}

// collectOpts shapes how collect acks.
type collectOpts struct {
	out, err uint64 // offsets the channel starts from
	// stop, when set, ends collecting early once it returns true.
	stop func(r *procResult) bool
}

// collect reads proc channel ch until its exit, acking at least every
// quarter window and checking the runner stays within the window.
func (fc *fakeConn) collect(t *testing.T, ch uint32, o collectOpts) *procResult {
	t.Helper()
	res := &procResult{}
	start := [3]uint64{0, o.out, o.err}
	acked := start
	got := start
	window := uint64(fc.r.window)
	for {
		e := fc.next(t)
		if f := e.frame; f != nil {
			if f.ch != ch {
				continue
			}
			if f.stream != 1 && f.stream != 2 {
				t.Fatalf("frame on stream %d", f.stream)
			}
			if f.off != got[f.stream] {
				t.Fatalf("stream %d: frame at %d, expected %d", f.stream, f.off, got[f.stream])
			}
			if len(f.data) > maxFramePayload {
				t.Fatalf("frame payload %d over 64 KiB", len(f.data))
			}
			end := f.off + uint64(len(f.data))
			if end-acked[f.stream] > window {
				t.Fatalf("stream %d: %d bytes past the ack, window %d", f.stream, end-acked[f.stream], window)
			}
			got[f.stream] = end
			if f.stream == 1 {
				res.out = append(res.out, f.data...)
			} else {
				res.err = append(res.err, f.data...)
			}
			if got[f.stream]-acked[f.stream] >= window/4 {
				acked[f.stream] = got[f.stream]
				fc.send(msg{"t": "ack", "ch": ch, "stream": f.stream, "offset": acked[f.stream]})
			}
			if o.stop != nil && o.stop(res) {
				return res
			}
			continue
		}
		m := e.msg
		switch m.str("t") {
		case "started":
			res.started = m
		case "eof":
			if uint32(m.num("ch")) == ch {
				res.eofs++
			}
		case "exit":
			res.exit = m
			if uint64(m.num("out")) != got[1] || uint64(m.num("err")) != got[2] {
				t.Fatalf("exit sizes out=%v err=%v, got %d and %d", m["out"], m["err"], got[1], got[2])
			}
			return res
		case "close":
			if uint32(m.num("ch")) == ch {
				t.Fatalf("channel %d closed: %v", ch, m["error"])
			}
		}
	}
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

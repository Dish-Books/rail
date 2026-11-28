package main

import (
	"context"
	"encoding/json"
	"errors"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

var errSessionClosed = errors.New("connection to Rail closed")

// channel is one end of a channel numbered on a session.
type channel interface {
	onData(stream uint8, offset uint64, payload []byte)
	onAck(stream uint8, offset uint64)
	onEOF(stream uint8)
	onClose(m inMsg)
	// stop ends the channel without telling Rail: the connection is gone, or
	// the channel's process is done.
	stop()
}

// session is one WebSocket connection to Rail. Channel numbers and pending
// sign requests last only as long as it does.
type session struct {
	d      *daemon
	c      *websocket.Conn
	ctx    context.Context
	cancel context.CancelFunc

	// One writer takes from these. Control messages go first; data frames are
	// handed over one at a time by each channel, and Go serves blocked senders
	// in order, so channels take turns.
	ctrl chan []byte
	data chan []byte

	window atomic.Int64
	pingMs atomic.Int64

	mu       sync.Mutex
	chans    map[uint32]channel
	nextCh   uint32
	signSeq  int64
	signWait map[int64]chan inMsg
}

func newSession(parent context.Context, d *daemon, c *websocket.Conn) *session {
	ctx, cancel := context.WithCancel(parent)
	s := &session{
		d: d, c: c, ctx: ctx, cancel: cancel,
		ctrl:     make(chan []byte),
		data:     make(chan []byte),
		chans:    map[uint32]channel{},
		nextCh:   2,
		signWait: map[int64]chan inMsg{},
	}
	s.window.Store(defaultWindow)
	s.pingMs.Store(defaultPingMs)
	return s
}

func (s *session) run() (welcomed bool, err error) {
	defer s.c.CloseNow()

	// hello goes first, before the writer starts.
	hello, err := json.Marshal(s.d.hello())
	if err != nil {
		return false, err
	}
	if err := s.c.Write(s.ctx, websocket.MessageText, hello); err != nil {
		return false, err
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); s.writer() }()
	go func() { defer wg.Done(); s.pinger() }()

	var welcomedFlag bool
	err = s.reader(&welcomedFlag)
	s.cancel()
	s.d.clearSession(s)
	s.teardown()
	wg.Wait()
	return welcomedFlag, err
}

func (s *session) writer() {
	write := func(typ websocket.MessageType, b []byte) bool {
		if err := s.c.Write(s.ctx, typ, b); err != nil {
			s.cancel()
			return false
		}
		return true
	}
	for {
		select {
		case b := <-s.ctrl:
			if !write(websocket.MessageText, b) {
				return
			}
			continue
		default:
		}
		select {
		case b := <-s.ctrl:
			if !write(websocket.MessageText, b) {
				return
			}
		case b := <-s.data:
			if !write(websocket.MessageBinary, b) {
				return
			}
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *session) pinger() {
	for {
		every := time.Duration(s.pingMs.Load()) * time.Millisecond
		select {
		case <-s.ctx.Done():
			return
		case <-time.After(every):
		}
		ctx, cancel := context.WithTimeout(s.ctx, max(every, 5*time.Second))
		err := s.c.Ping(ctx)
		cancel()
		if err != nil {
			s.d.log.Printf("ping: %v", err)
			s.cancel()
			return
		}
	}
}

func (s *session) reader(welcomed *bool) error {
	for {
		typ, b, err := s.c.Read(s.ctx)
		if err != nil {
			return err
		}
		if typ == websocket.MessageBinary {
			ch, stream, off, payload, err := decodeFrame(b)
			if err != nil {
				s.d.log.Printf("frame: %v", err)
				continue
			}
			if c := s.channel(ch); c != nil {
				c.onData(stream, off, payload)
			}
			continue
		}
		var m inMsg
		if err := json.Unmarshal(b, &m); err != nil {
			s.d.log.Printf("control message: %v", err)
			continue
		}
		if m.T == "welcome" && !*welcomed {
			*welcomed = true
			if m.Window > 0 {
				s.window.Store(m.Window)
			}
			if m.PingMs > 0 {
				s.pingMs.Store(m.PingMs)
			}
			s.d.setSession(s)
			continue
		}
		s.d.handle(s, m)
	}
}

func (s *session) teardown() {
	s.mu.Lock()
	chans := s.chans
	s.chans = map[uint32]channel{}
	waits := s.signWait
	s.signWait = map[int64]chan inMsg{}
	s.mu.Unlock()
	for _, c := range chans {
		c.stop()
	}
	for _, w := range waits {
		w <- inMsg{T: "signed", Error: errSessionClosed.Error()}
	}
}

// sendJSON queues a control message. It fails once the session is over.
func (s *session) sendJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	select {
	case s.ctrl <- b:
		return nil
	case <-s.ctx.Done():
		return errSessionClosed
	}
}

// sendFrame hands one frame to the writer, waiting its turn. It fails once
// ctx or the session is over.
func (s *session) sendFrame(ctx context.Context, ch uint32, stream uint8, off uint64, p []byte) error {
	b := encodeFrame(ch, stream, off, p)
	select {
	case s.data <- b:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-s.ctx.Done():
		return errSessionClosed
	}
}

func (s *session) channel(ch uint32) channel {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.chans[ch]
}

func (s *session) register(ch uint32, c channel) {
	s.mu.Lock()
	old := s.chans[ch]
	s.chans[ch] = c
	s.mu.Unlock()
	if old != nil {
		old.stop()
	}
}

// unregister removes channel ch if it is still c.
func (s *session) unregister(ch uint32, c channel) {
	s.mu.Lock()
	if s.chans[ch] == c {
		delete(s.chans, ch)
	}
	s.mu.Unlock()
}

// openChannel numbers a runner-opened channel (even) and registers it.
func (s *session) openChannel(newChan func(ch uint32) channel) (uint32, channel) {
	s.mu.Lock()
	ch := s.nextCh
	s.nextCh += 2
	c := newChan(ch)
	s.chans[ch] = c
	s.mu.Unlock()
	return ch, c
}

// sign asks Rail to sign payload (base64) and waits for the answer.
func (s *session) sign(payload string, timeout time.Duration) (string, error) {
	s.mu.Lock()
	s.signSeq++
	id := s.signSeq
	w := make(chan inMsg, 1)
	s.signWait[id] = w
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.signWait, id)
		s.mu.Unlock()
	}()
	if err := s.sendJSON(signMsg{T: "sign", ID: id, Payload: payload}); err != nil {
		return "", err
	}
	select {
	case m := <-w:
		if m.Error != "" {
			return "", errors.New(m.Error)
		}
		if m.Signature == "" {
			return "", errors.New("Rail sent no signature")
		}
		return m.Signature, nil
	case <-time.After(timeout):
		return "", errors.New("timed out waiting for Rail to sign")
	}
}

func (s *session) signed(m inMsg) {
	id, err := strconv.ParseInt(string(m.ID), 10, 64)
	if err != nil {
		s.d.log.Printf("signed: id %s", m.ID)
		return
	}
	s.mu.Lock()
	w := s.signWait[id]
	delete(s.signWait, id)
	s.mu.Unlock()
	if w != nil {
		w <- m
	}
}

// handle acts on one control message from Rail. It runs on the reader, so
// anything slow goes to its own goroutine.
func (d *daemon) handle(s *session, m inMsg) {
	switch m.T {
	case "welcome":
		// A second welcome changes nothing.
	case "exec":
		d.exec(s, m)
	case "resume":
		d.resume(s, m)
	case "done":
		d.done(s, m)
	case "signal":
		d.signal(m)
	case "signed":
		s.signed(m)
	case "head":
		if h, ok := s.channel(m.Ch).(*httpChan); ok {
			h.onHead(m)
		}
	case "call":
		go d.call(s, m)
	case "ack":
		if c := s.channel(m.Ch); c != nil {
			c.onAck(m.Stream, m.Offset)
		}
	case "eof":
		if c := s.channel(m.Ch); c != nil {
			c.onEOF(m.Stream)
		}
	case "close":
		if c := s.channel(m.Ch); c != nil {
			s.unregister(m.Ch, c)
			c.onClose(m)
		}
	case "open":
		// Rail opens proc channels with exec and resume; any other kind is
		// one this runner does not serve.
		_ = s.sendJSON(closeMsg{T: "close", Ch: m.Ch, Error: "unsupported"})
	default:
		d.log.Printf("unknown control message %q", m.T)
	}
}

func (d *daemon) hello() helloMsg {
	d.mu.Lock()
	procs := make([]*proc, 0, len(d.procs))
	for _, p := range d.procs {
		procs = append(procs, p)
	}
	d.mu.Unlock()
	sortProcs(procs)
	h := helloMsg{T: "hello", Runner: d.cfg.Version, OS: runtime.GOOS, Arch: runtime.GOARCH, Procs: []helloProc{}}
	for _, p := range procs {
		state := "running"
		if p.hasExited() {
			state = "exited"
		}
		h.Procs = append(h.Procs, helloProc{ID: p.rawID, State: state, Out: fileSize(p.outPath()), Err: fileSize(p.errPath())})
	}
	return h
}

// flow is one direction of one stream as seen by its sender: how far the
// receiver has acked, so the sender keeps within the window.
type flow struct {
	mu     sync.Mutex
	acked  uint64
	notify chan struct{}
}

func newFlow(acked uint64) *flow { return &flow{acked: acked, notify: make(chan struct{}, 1)} }

func (f *flow) ack(off uint64) {
	f.mu.Lock()
	if off > f.acked {
		f.acked = off
	}
	f.mu.Unlock()
	select {
	case f.notify <- struct{}{}:
	default:
	}
}

// room waits until the sender, at sent, may send more, and says how much.
func (f *flow) room(ctx context.Context, sent uint64, window int64) (int, error) {
	for {
		f.mu.Lock()
		limit := f.acked + uint64(window)
		f.mu.Unlock()
		if limit > sent {
			return int(min(limit-sent, maxFramePayload)), nil
		}
		select {
		case <-f.notify:
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}
}

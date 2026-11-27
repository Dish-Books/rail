package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
)

// Binary frames: | channel: u32 | stream: u8 | offset: u64 | payload |,
// big-endian, payload at most 64 KiB.
const (
	frameHeaderLen  = 13
	maxFramePayload = 64 << 10
	defaultWindow   = 1 << 20
	defaultPingMs   = 20_000
)

func encodeFrame(ch uint32, stream uint8, offset uint64, payload []byte) []byte {
	b := make([]byte, frameHeaderLen+len(payload))
	binary.BigEndian.PutUint32(b[0:4], ch)
	b[4] = stream
	binary.BigEndian.PutUint64(b[5:13], offset)
	copy(b[frameHeaderLen:], payload)
	return b
}

func decodeFrame(b []byte) (ch uint32, stream uint8, offset uint64, payload []byte, err error) {
	if len(b) < frameHeaderLen {
		return 0, 0, 0, nil, errors.New("short binary frame")
	}
	if len(b)-frameHeaderLen > maxFramePayload {
		return 0, 0, 0, nil, errors.New("binary frame payload over 64 KiB")
	}
	return binary.BigEndian.Uint32(b[0:4]), b[4], binary.BigEndian.Uint64(b[5:13]), b[frameHeaderLen:], nil
}

// inMsg is any control message from Rail. Only the fields its "t" uses are set.
type inMsg struct {
	T string `json:"t"`

	// welcome
	Window int64 `json:"window"`
	PingMs int64 `json:"ping_ms"`

	// exec, resume, done, signal, signed, call
	ID json.RawMessage `json:"id"`
	Ch uint32          `json:"ch"`

	// exec
	Argv   []string          `json:"argv"`
	Env    map[string]string `json:"env"`
	Cwd    string            `json:"cwd"`
	Files  []fileSpec        `json:"files"`
	Stdin  string            `json:"stdin"`
	Stderr string            `json:"stderr"`

	// resume
	Out uint64 `json:"out"`
	Err uint64 `json:"err"`

	// signal
	Signal string `json:"signal"`

	// signed
	Signature string `json:"signature"`
	Error     string `json:"error"`

	// call
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`

	// ack, eof
	Stream uint8  `json:"stream"`
	Offset uint64 `json:"offset"`

	// close
	Code *int `json:"code"`

	// open
	Kind    string `json:"kind"`
	Service string `json:"service"`
}

// fileSpec is one entry of exec's, checkout's and write's "files".
type fileSpec struct {
	Path string   `json:"path"`
	Data string   `json:"data"` // base64
	Mode fileMode `json:"mode"`
}

// fileMode accepts a JSON number (420) or an octal string ("0644").
type fileMode uint32

func (m *fileMode) UnmarshalJSON(b []byte) error {
	if string(b) == "null" {
		*m = 0
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		v, err := strconv.ParseUint(s, 8, 32)
		if err != nil {
			return fmt.Errorf("file mode %q: %w", s, err)
		}
		*m = fileMode(v)
		return nil
	}
	var n uint32
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("file mode %s: %w", b, err)
	}
	*m = fileMode(n)
	return nil
}

// Runner to Rail.

type helloProc struct {
	ID    json.RawMessage `json:"id"`
	State string          `json:"state"`
	Out   int64           `json:"out"`
	Err   int64           `json:"err"`
}

type helloMsg struct {
	T      string      `json:"t"`
	Runner string      `json:"runner"`
	OS     string      `json:"os"`
	Arch   string      `json:"arch"`
	Procs  []helloProc `json:"procs"`
}

type startedMsg struct {
	T   string          `json:"t"`
	ID  json.RawMessage `json:"id"`
	PID int             `json:"pid"`
}

type exitMsg struct {
	T      string          `json:"t"`
	ID     json.RawMessage `json:"id"`
	Code   int             `json:"code"`
	Signal *string         `json:"signal"`
	OOM    bool            `json:"oom"`
	Out    int64           `json:"out"`
	Err    int64           `json:"err"`
}

type openMsg struct {
	T       string `json:"t"`
	Ch      uint32 `json:"ch"`
	Kind    string `json:"kind"`
	Service string `json:"service,omitempty"`
}

type signMsg struct {
	T       string `json:"t"`
	ID      int64  `json:"id"`
	Payload string `json:"payload"`
}

type replyMsg struct {
	T      string          `json:"t"`
	ID     json.RawMessage `json:"id"`
	OK     bool            `json:"ok"`
	Result any             `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// Either way.

type ackMsg struct {
	T      string `json:"t"`
	Ch     uint32 `json:"ch"`
	Stream uint8  `json:"stream"`
	Offset uint64 `json:"offset"`
}

type eofMsg struct {
	T      string `json:"t"`
	Ch     uint32 `json:"ch"`
	Stream uint8  `json:"stream"`
}

type closeMsg struct {
	T     string `json:"t"`
	Ch    uint32 `json:"ch"`
	Error string `json:"error,omitempty"`
	Code  *int   `json:"code,omitempty"`
}

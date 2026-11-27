package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// A process's spool, $RAIL_RUNNER_STATE/procs/<id>/:
//
//	spec.json  what Rail asked for (no file contents or stdin)
//	stdin      the decoded stdin, when there was one
//	stdout     the command's stdout (and stderr, with "merge")
//	stderr     the command's stderr
//	pid        the pid, once started
//	exit.json  {code, signal, oom}, once it has exited
const (
	specFile   = "spec.json"
	stdinFile  = "stdin"
	stdoutFile = "stdout"
	stderrFile = "stderr"
	pidFile    = "pid"
	exitFile   = "exit.json"

	spoolPoll = 50 * time.Millisecond
	alivePoll = 250 * time.Millisecond
)

type procSpec struct {
	ID        json.RawMessage   `json:"id"`
	Argv      []string          `json:"argv"`
	Env       map[string]string `json:"env,omitempty"`
	Cwd       string            `json:"cwd,omitempty"`
	Stderr    string            `json:"stderr,omitempty"`
	OOMBefore *int64            `json:"oom_before,omitempty"`
}

type exitRecord struct {
	Code   int     `json:"code"`
	Signal *string `json:"signal"`
	OOM    bool    `json:"oom"`
}

type proc struct {
	id    string          // the folder's name
	rawID json.RawMessage // the id as Rail sent it, echoed back as is
	dir   string

	mu     sync.Mutex
	pid    int
	exited bool
	exit   exitRecord
	exitCh chan struct{} // closed once exited
	gone   chan struct{} // closed by done
}

func newProc(dir, id string, rawID json.RawMessage) *proc {
	return &proc{id: id, rawID: rawID, dir: dir, exitCh: make(chan struct{}), gone: make(chan struct{})}
}

func (p *proc) outPath() string { return filepath.Join(p.dir, stdoutFile) }
func (p *proc) errPath() string { return filepath.Join(p.dir, stderrFile) }

func (p *proc) hasExited() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited
}

func (p *proc) exitRecord() exitRecord {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exit
}

func (p *proc) runningPID() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.exited {
		return 0
	}
	return p.pid
}

// finish records the exit in exit.json and wakes the stream readers.
func (p *proc) finish(rec exitRecord) {
	if b, err := json.Marshal(rec); err == nil {
		_ = writeFileAtomic(filepath.Join(p.dir, exitFile), b, 0o600)
	}
	p.mu.Lock()
	if !p.exited {
		p.exited = true
		p.exit = rec
		close(p.exitCh)
	}
	p.mu.Unlock()
}

// procID turns Rail's id (an os_process_id, number or string) into a folder name.
func procID(raw json.RawMessage) (string, error) {
	var id string
	var n json.Number
	if err := json.Unmarshal(raw, &id); err != nil {
		if err := json.Unmarshal(raw, &n); err != nil {
			return "", fmt.Errorf("process id %s is neither a string nor a number", raw)
		}
		id = n.String()
	}
	if id == "" || id == "." || id == ".." || len(id) > 200 || strings.ContainsAny(id, "/\x00") {
		return "", fmt.Errorf("process id %q can't name a folder", id)
	}
	return id, nil
}

func (d *daemon) lookupProc(raw json.RawMessage) *proc {
	id, err := procID(raw)
	if err != nil {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.procs[id]
}

// exec starts a command, unless its id is already known.
func (d *daemon) exec(s *session, m inMsg) {
	id, err := procID(m.ID)
	if err != nil {
		_ = s.sendJSON(closeMsg{T: "close", Ch: m.Ch, Error: err.Error()})
		return
	}
	d.mu.Lock()
	if _, known := d.procs[id]; known {
		d.mu.Unlock()
		return
	}
	p := newProc(filepath.Join(d.procsDir(), id), id, m.ID)
	d.procs[id] = p
	d.mu.Unlock()

	if err := d.start(s, p, m); err != nil {
		// The command never ran: say why on its stderr and record a 127 exit,
		// so it settles like any other.
		d.log.Printf("exec %s: %v", id, err)
		if f, ferr := os.OpenFile(p.errPath(), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600); ferr == nil {
			fmt.Fprintf(f, "rail-runner: %v\n", err)
			f.Close()
		}
		_ = touch(p.outPath())
		if _, err := os.Stat(filepath.Join(p.dir, specFile)); err != nil {
			if b, err := json.Marshal(procSpec{ID: m.ID, Argv: m.Argv, Cwd: m.Cwd}); err == nil {
				_ = writeFileAtomic(filepath.Join(p.dir, specFile), b, 0o600)
			}
		}
		p.finish(exitRecord{Code: 127})
	}
	d.serveProc(s, m.Ch, p, 0, 0)
}

func (d *daemon) start(s *session, p *proc, m inMsg) error {
	if err := os.MkdirAll(p.dir, 0o700); err != nil {
		return err
	}
	if len(m.Argv) == 0 {
		return errors.New("empty argv")
	}
	if err := d.writeFilesAs(m.Cwd, m.Files); err != nil {
		return err
	}
	spec := procSpec{ID: m.ID, Argv: m.Argv, Env: m.Env, Cwd: m.Cwd, Stderr: m.Stderr}
	oomBefore, oomKnown := readOOMKills()
	if oomKnown {
		spec.OOMBefore = &oomBefore
	}
	b, err := json.Marshal(spec)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(filepath.Join(p.dir, specFile), b, 0o600); err != nil {
		return err
	}

	outF, err := os.OpenFile(p.outPath(), os.O_WRONLY|os.O_CREATE|os.O_TRUNC|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer outF.Close()
	errF, err := os.OpenFile(p.errPath(), os.O_WRONLY|os.O_CREATE|os.O_TRUNC|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer errF.Close()

	var stdin *os.File
	if m.Stdin != "" {
		data, err := base64.StdEncoding.DecodeString(m.Stdin)
		if err != nil {
			return fmt.Errorf("stdin is not base64: %w", err)
		}
		path := filepath.Join(p.dir, stdinFile)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			return err
		}
		stdin, err = os.Open(path)
		if err != nil {
			return err
		}
	} else {
		stdin, err = os.Open(os.DevNull)
		if err != nil {
			return err
		}
	}
	defer stdin.Close()

	env := d.cmdEnv(m.Env)
	path, _ := envGet(env, "PATH")
	argv0, err := lookPath(m.Argv[0], path)
	if err != nil {
		return err
	}
	cmd := &exec.Cmd{
		Path:        argv0,
		Args:        m.Argv,
		Env:         env,
		Dir:         m.Cwd,
		Stdin:       stdin,
		Stdout:      outF,
		Stderr:      errF,
		SysProcAttr: &syscall.SysProcAttr{Setpgid: true, Credential: d.cred()},
	}
	if m.Stderr == "merge" {
		cmd.Stderr = outF
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	pid := cmd.Process.Pid
	_ = writeFileAtomic(filepath.Join(p.dir, pidFile), []byte(strconv.Itoa(pid)), 0o600)
	p.mu.Lock()
	p.pid = pid
	p.mu.Unlock()
	_ = s.sendJSON(startedMsg{T: "started", ID: p.rawID, PID: pid})

	go func() {
		_ = cmd.Wait()
		rec := exitRecord{Code: -1}
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok {
			if ws.Signaled() {
				name := signalName(ws.Signal())
				rec.Signal = &name
			} else {
				rec.Code = ws.ExitStatus()
			}
		}
		rec.OOM = oomSince(spec.OOMBefore)
		p.finish(rec)
	}()
	return nil
}

func (d *daemon) resume(s *session, m inMsg) {
	p := d.lookupProc(m.ID)
	if p == nil {
		_ = s.sendJSON(closeMsg{T: "close", Ch: m.Ch, Error: "unknown process"})
		return
	}
	d.serveProc(s, m.Ch, p, m.Out, m.Err)
}

func (d *daemon) done(s *session, m inMsg) {
	id, err := procID(m.ID)
	if err != nil {
		return
	}
	d.mu.Lock()
	p := d.procs[id]
	delete(d.procs, id)
	d.mu.Unlock()
	if p == nil {
		return
	}
	stopProcChannels(s, p, 0)
	close(p.gone)
	// Rail has settled it; anything still running of it goes.
	if pid := p.runningPID(); pid > 0 {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}
	if err := os.RemoveAll(p.dir); err != nil {
		d.log.Printf("done %s: %v", id, err)
	}
}

func (d *daemon) signal(m inMsg) {
	p := d.lookupProc(m.ID)
	if p == nil {
		return
	}
	sig, ok := signalsByName[m.Signal]
	if !ok {
		d.log.Printf("signal %q: unknown", m.Signal)
		return
	}
	if pid := p.runningPID(); pid > 0 {
		if err := syscall.Kill(-pid, sig); err != nil && !errors.Is(err, syscall.ESRCH) {
			d.log.Printf("signal %s to %s: %v", m.Signal, p.id, err)
		}
	}
}

// adoptProcs takes back the processes in procs/ that a previous run of the
// daemon started.
func (d *daemon) adoptProcs(ctx context.Context) error {
	entries, err := os.ReadDir(d.procsDir())
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(d.procsDir(), e.Name())
		var spec procSpec
		b, err := os.ReadFile(filepath.Join(dir, specFile))
		if err == nil {
			err = json.Unmarshal(b, &spec)
		}
		if err != nil {
			// Never got as far as starting: Rail will exec it again.
			d.log.Printf("dropping %s: no spec: %v", dir, err)
			_ = os.RemoveAll(dir)
			continue
		}
		id, err := procID(spec.ID)
		if err != nil || id != e.Name() {
			d.log.Printf("dropping %s: id %s", dir, spec.ID)
			_ = os.RemoveAll(dir)
			continue
		}
		p := newProc(dir, id, spec.ID)
		var rec exitRecord
		if b, err := os.ReadFile(filepath.Join(dir, exitFile)); err == nil && json.Unmarshal(b, &rec) == nil {
			p.exited, p.exit = true, rec
			close(p.exitCh)
		} else {
			b, _ := os.ReadFile(filepath.Join(dir, pidFile))
			pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
			p.pid = pid
			if pid > 0 && alive(pid) {
				go d.watchAdopted(ctx, p, spec.OOMBefore)
			} else {
				p.finish(exitRecord{Code: -1, OOM: oomSince(spec.OOMBefore)})
			}
		}
		d.mu.Lock()
		d.procs[id] = p
		d.mu.Unlock()
	}
	return nil
}

// watchAdopted polls a process this daemon did not start, and so cannot wait
// for, until it is gone. Its exit status is lost: it exits with code -1.
func (d *daemon) watchAdopted(ctx context.Context, p *proc, oomBefore *int64) {
	t := time.NewTicker(alivePoll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-p.gone:
			return
		case <-t.C:
		}
		if !alive(p.pid) {
			p.finish(exitRecord{Code: -1, OOM: oomSince(oomBefore)})
			return
		}
	}
}

func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// procChan sends one process's stdout and stderr on a channel Rail opened
// with exec or resume.
type procChan struct {
	s      *session
	ch     uint32
	p      *proc
	ctx    context.Context
	cancel context.CancelFunc
	flows  [3]*flow
}

func (d *daemon) serveProc(s *session, ch uint32, p *proc, out, errOff uint64) {
	stopProcChannels(s, p, ch)
	ctx, cancel := context.WithCancel(s.ctx)
	pc := &procChan{s: s, ch: ch, p: p, ctx: ctx, cancel: cancel}
	pc.flows[1] = newFlow(out)
	pc.flows[2] = newFlow(errOff)
	s.register(ch, pc)
	go pc.serve(out, errOff)
}

// stopProcChannels stops every channel on s sending p, but for channel except.
func stopProcChannels(s *session, p *proc, except uint32) {
	s.mu.Lock()
	var stop []channel
	for ch, c := range s.chans {
		if pc, ok := c.(*procChan); ok && pc.p == p && ch != except {
			delete(s.chans, ch)
			stop = append(stop, c)
		}
	}
	s.mu.Unlock()
	for _, c := range stop {
		c.stop()
	}
}

func (pc *procChan) onData(uint8, uint64, []byte) {}
func (pc *procChan) onEOF(uint8)                  {}
func (pc *procChan) onClose(inMsg)                { pc.cancel() }
func (pc *procChan) stop()                        { pc.cancel() }
func (pc *procChan) onAck(stream uint8, off uint64) {
	if stream == 1 || stream == 2 {
		pc.flows[stream].ack(off)
	}
}

func (pc *procChan) serve(out, errOff uint64) {
	defer pc.s.unregister(pc.ch, pc)
	defer pc.cancel()
	var wg sync.WaitGroup
	var ends [3]uint64
	var errs [3]error
	wg.Add(2)
	for stream, start := range map[uint8]uint64{1: out, 2: errOff} {
		path := pc.p.outPath()
		if stream == 2 {
			path = pc.p.errPath()
		}
		go func() {
			defer wg.Done()
			ends[stream], errs[stream] = pc.stream(stream, path, start)
		}()
	}
	wg.Wait()
	if pc.ctx.Err() != nil {
		return
	}
	for _, err := range errs[1:] {
		if err != nil {
			pc.s.d.log.Printf("process %s: %v", pc.p.id, err)
			_ = pc.s.sendJSON(closeMsg{T: "close", Ch: pc.ch, Error: err.Error()})
			pc.s.unregister(pc.ch, pc)
			return
		}
	}
	_ = pc.s.sendJSON(eofMsg{T: "eof", Ch: pc.ch, Stream: 1})
	_ = pc.s.sendJSON(eofMsg{T: "eof", Ch: pc.ch, Stream: 2})
	rec := pc.p.exitRecord()
	_ = pc.s.sendJSON(exitMsg{
		T: "exit", ID: pc.p.rawID, Code: rec.Code, Signal: rec.Signal, OOM: rec.OOM,
		Out: int64(ends[1]), Err: int64(ends[2]),
	})
}

// stream sends one spool file from off until the process has exited and the
// file is read to its end, keeping within the window. It returns the final
// offset.
func (pc *procChan) stream(stream uint8, path string, off uint64) (uint64, error) {
	var f *os.File
	defer func() {
		if f != nil {
			f.Close()
		}
	}()
	buf := make([]byte, maxFramePayload)
	for {
		room, err := pc.flows[stream].room(pc.ctx, off, pc.s.window.Load())
		if err != nil {
			return off, err
		}
		// Look at the exit before reading, so a read that finds nothing new
		// after it means the file is complete.
		exited := pc.p.hasExited()
		if f == nil {
			f, err = os.Open(path)
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return off, err
			}
		}
		n := 0
		if f != nil {
			n, err = f.ReadAt(buf[:room], int64(off))
			if err != nil && !errors.Is(err, io.EOF) {
				return off, err
			}
		}
		if n > 0 {
			if err := pc.s.sendFrame(pc.ctx, pc.ch, stream, off, buf[:n]); err != nil {
				return off, err
			}
			off += uint64(n)
			continue
		}
		if exited {
			return off, nil
		}
		select {
		case <-pc.ctx.Done():
			return off, pc.ctx.Err()
		case <-pc.p.exitCh:
		case <-time.After(spoolPoll):
		}
	}
}

// readOOMKills reads oom_kill from the sandbox's cgroup (Linux, cgroup v2).
func readOOMKills() (int64, bool) {
	f, err := os.Open("/sys/fs/cgroup/memory.events")
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := bytes.Cut(sc.Bytes(), []byte(" "))
		if ok && string(k) == "oom_kill" {
			n, err := strconv.ParseInt(string(v), 10, 64)
			return n, err == nil
		}
	}
	return 0, false
}

func oomSince(before *int64) bool {
	if before == nil {
		return false
	}
	after, ok := readOOMKills()
	return ok && after > *before
}

var signalsByName = map[string]syscall.Signal{
	"TERM": syscall.SIGTERM, "KILL": syscall.SIGKILL, "INT": syscall.SIGINT,
	"HUP": syscall.SIGHUP, "QUIT": syscall.SIGQUIT,
}

func signalName(sig syscall.Signal) string {
	switch sig {
	case syscall.SIGTERM:
		return "TERM"
	case syscall.SIGKILL:
		return "KILL"
	case syscall.SIGINT:
		return "INT"
	case syscall.SIGHUP:
		return "HUP"
	case syscall.SIGQUIT:
		return "QUIT"
	case syscall.SIGSEGV:
		return "SEGV"
	case syscall.SIGABRT:
		return "ABRT"
	case syscall.SIGPIPE:
		return "PIPE"
	case syscall.SIGBUS:
		return "BUS"
	case syscall.SIGILL:
		return "ILL"
	case syscall.SIGFPE:
		return "FPE"
	case syscall.SIGUSR1:
		return "USR1"
	case syscall.SIGUSR2:
		return "USR2"
	case syscall.SIGALRM:
		return "ALRM"
	}
	return strconv.Itoa(int(sig))
}

func sortProcs(ps []*proc) {
	sort.Slice(ps, func(i, j int) bool {
		a, b := ps[i].id, ps[j].id
		if len(a) != len(b) {
			return len(a) < len(b)
		}
		return a < b
	})
}

func fileSize(path string) int64 {
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.Size()
}

func touch(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	return f.Close()
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

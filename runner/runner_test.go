package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// runnerBin is the real binary, built once, that the daemon links its shims
// to, so git-remote-rail and rail-sign run for real.
var runnerBin string

func TestMain(m *testing.M) {
	os.Exit(testMain(m))
}

func testMain(m *testing.M) int {
	dir, err := os.MkdirTemp("", "rail-runner-bin")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(dir)
	runnerBin = filepath.Join(dir, "rail-runner")
	if prebuilt := os.Getenv("RAIL_RUNNER_TEST_BIN"); prebuilt != "" {
		// For running a compiled test binary where there is no Go toolchain.
		runnerBin = prebuilt
	} else if err := buildRunner(runnerBin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	// Keep the developer's git config out of the tests.
	empty := filepath.Join(dir, "gitconfig")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	os.Setenv("GIT_CONFIG_GLOBAL", empty)
	os.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	return m.Run()
}

func buildRunner(out string) error {
	goTool := filepath.Join(runtime.GOROOT(), "bin", "go")
	if _, err := os.Stat(goTool); err != nil {
		goTool = "go"
	}
	build := exec.Command(goTool, "build", "-o", out, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if b, err := build.CombinedOutput(); err != nil {
		return fmt.Errorf("building rail-runner: %v\n%s", err, b)
	}
	return nil
}

// shortTempDir is a temp folder with a short path: a unix socket's path is
// limited to about 100 bytes, and macOS's $TMPDIR is long.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "rr")
	if err != nil {
		t.Fatal(err)
	}
	dir, _ = filepath.EvalSymlinks(dir)
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

type testDaemon struct {
	*daemon
	state string
	stop  func()
}

func startDaemon(t *testing.T, r *fakeRail, state string, opts ...func(*config)) *testDaemon {
	t.Helper()
	if state == "" {
		state = shortTempDir(t)
	}
	logOut := io.Discard
	if os.Getenv("RUNNER_TEST_LOG") != "" {
		logOut = os.Stderr
	}
	cfg := config{
		URL: r.url(), Token: r.token, State: state,
		UID: os.Getuid(), GID: os.Getgid(),
		Exe: runnerBin, Version: "test",
		MinBackoff: 20 * time.Millisecond, MaxBackoff: 200 * time.Millisecond,
		Log: log.New(logOut, "rail-runner: ", log.Lmicroseconds),
	}
	for _, o := range opts {
		o(&cfg)
	}
	d := newDaemon(cfg)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- d.Run(ctx) }()
	stopped := false
	stop := func() {
		if !stopped {
			stopped = true
			cancel()
			<-done
		}
	}
	t.Cleanup(stop)
	return &testDaemon{daemon: d, state: state, stop: stop}
}

func TestFrameRoundTrip(t *testing.T) {
	b := encodeFrame(7, 2, 1<<40, []byte("hi"))
	if len(b) != frameHeaderLen+2 {
		t.Fatalf("len %d", len(b))
	}
	if !bytes.Equal(b[:frameHeaderLen], []byte{0, 0, 0, 7, 2, 0, 0, 1, 0, 0, 0, 0, 0}) {
		t.Fatalf("header % x", b[:frameHeaderLen])
	}
	ch, stream, off, p, err := decodeFrame(b)
	if err != nil || ch != 7 || stream != 2 || off != 1<<40 || string(p) != "hi" {
		t.Fatalf("decoded %d %d %d %q %v", ch, stream, off, p, err)
	}
	if _, _, _, _, err := decodeFrame(make([]byte, frameHeaderLen+maxFramePayload+1)); err == nil {
		t.Fatal("accepted an oversized frame")
	}
}

func TestFileMode(t *testing.T) {
	var f struct{ A, B, C fileMode }
	if err := json.Unmarshal([]byte(`{"A":493,"B":"0600","C":null}`), &f); err != nil {
		t.Fatal(err)
	}
	if f.A != 0o755 || f.B != 0o600 || f.C != 0 {
		t.Fatalf("%o %o %o", f.A, f.B, f.C)
	}
}

func TestHelloAndExec(t *testing.T) {
	r := newFakeRail(t)
	td := startDaemon(t, r, "", func(c *config) { c.AccessID, c.AccessSecret = "cf-id", "cf-secret" })
	fc := r.next(t)

	if got := fc.header.Get("X-Rail-Runner"); got != "test" {
		t.Errorf("X-Rail-Runner %q", got)
	}
	if fc.header.Get("CF-Access-Client-Id") != "cf-id" || fc.header.Get("CF-Access-Client-Secret") != "cf-secret" {
		t.Errorf("Cloudflare Access headers %v", fc.header)
	}
	if fc.hello.str("os") != runtime.GOOS || fc.hello.str("arch") != runtime.GOARCH || fc.hello.str("runner") != "test" {
		t.Errorf("hello %v", fc.hello)
	}
	if procs, ok := fc.hello["procs"].([]any); !ok || len(procs) != 0 {
		t.Errorf("hello procs %v", fc.hello["procs"])
	}
	for _, name := range []string{"git-remote-rail", "rail-sign"} {
		if target, err := os.Readlink(filepath.Join(td.state, "bin", name)); err != nil || target != runnerBin {
			t.Errorf("bin/%s -> %q, %v", name, target, err)
		}
	}

	cwd := t.TempDir()
	fc.send(msg{
		"t": "exec", "id": 101, "ch": 1,
		"argv":   []string{"sh", "-c", `cat; printf '%s' "$GREETING" >&2; cat sub/f.txt >&2; echo "$PATH" > path.txt; exit 3`},
		"env":    map[string]string{"GREETING": "hi "},
		"cwd":    cwd,
		"files":  []any{map[string]any{"path": "sub/f.txt", "data": b64("world"), "mode": "0600"}},
		"stdin":  b64("hello"),
		"stderr": "separate",
	})
	res := fc.collect(t, 1, collectOpts{})
	if string(res.out) != "hello" || string(res.err) != "hi world" {
		t.Fatalf("out %q err %q", res.out, res.err)
	}
	if res.started == nil || res.started.num("pid") <= 0 || res.started["id"] != float64(101) {
		t.Errorf("started %v", res.started)
	}
	if res.eofs != 2 {
		t.Errorf("%d eofs", res.eofs)
	}
	if res.exit.num("code") != 3 || res.exit["signal"] != nil || res.exit["oom"] != false || res.exit["id"] != float64(101) {
		t.Errorf("exit %v", res.exit)
	}
	if st, err := os.Stat(filepath.Join(cwd, "sub/f.txt")); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("file: %v %v", st, err)
	}
	path, _ := os.ReadFile(filepath.Join(cwd, "path.txt"))
	if !strings.HasPrefix(string(path), filepath.Join(td.state, "bin")+":") {
		t.Errorf("PATH %q doesn't start with the shims", path)
	}
	for _, f := range []string{"spec.json", "exit.json", "stdout", "stderr", "pid"} {
		if _, err := os.Stat(filepath.Join(td.state, "procs", "101", f)); err != nil {
			t.Errorf("spool: %v", err)
		}
	}

	// stderr merged into stdout, and a string id.
	fc.send(msg{"t": "exec", "id": "p-2", "ch": 3, "argv": []string{"sh", "-c", "echo a; echo b >&2"}, "cwd": cwd, "stderr": "merge"})
	res = fc.collect(t, 3, collectOpts{})
	if string(res.out) != "a\nb\n" || len(res.err) != 0 || res.exit.num("code") != 0 || res.exit["id"] != "p-2" {
		t.Fatalf("merge: out %q err %q exit %v", res.out, res.err, res.exit)
	}

	// A known id is ignored.
	fc.send(msg{"t": "exec", "id": 101, "ch": 5, "argv": []string{"sh", "-c", "echo again"}, "cwd": cwd})
	// A command that can't start still exits, with why on stderr.
	fc.send(msg{"t": "exec", "id": 103, "ch": 7, "argv": []string{"no-such-command-xyz"}, "cwd": cwd})
	res = fc.collect(t, 7, collectOpts{})
	if res.exit.num("code") != 127 || !strings.Contains(string(res.err), "not found") {
		t.Fatalf("unstartable: err %q exit %v", res.err, res.exit)
	}
	if _, err := os.Stat(filepath.Join(td.state, "procs", "101")); err != nil {
		t.Fatal(err)
	}
}

func TestLargeOutputWindowAndAcks(t *testing.T) {
	r := newFakeRail(t)
	r.window = 128 << 10
	startDaemon(t, r, "")
	fc := r.next(t)

	const n = 300_000
	var want bytes.Buffer
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&want, "%d\n", i)
	}
	fc.send(msg{"t": "exec", "id": 1, "ch": 1, "argv": []string{"seq", "1", strconv.Itoa(n)}, "cwd": t.TempDir()})

	// With no acks, the runner stops at the window.
	var got []byte
	for len(got) < int(r.window) {
		e := fc.next(t)
		if e.frame != nil {
			if e.frame.off != uint64(len(got)) {
				t.Fatalf("frame at %d, expected %d", e.frame.off, len(got))
			}
			got = append(got, e.frame.data...)
		}
	}
	if len(got) != int(r.window) {
		t.Fatalf("sent %d with no ack, window %d", len(got), r.window)
	}
	select {
	case e := <-fc.events:
		if e.frame != nil {
			t.Fatalf("runner sent past the window: frame at %d", e.frame.off)
		}
	case <-time.After(300 * time.Millisecond):
	}

	fc.send(msg{"t": "ack", "ch": 1, "stream": 1, "offset": len(got)})
	res := fc.collect(t, 1, collectOpts{out: uint64(len(got))})
	got = append(got, res.out...)
	if !bytes.Equal(got, want.Bytes()) {
		t.Fatalf("got %d bytes, want %d", len(got), want.Len())
	}
	if res.exit.num("code") != 0 || res.exit.num("out") != int64(want.Len()) {
		t.Fatalf("exit %v", res.exit)
	}
}

func TestReconnectAndResume(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)

	script := `i=0; while [ $i -lt 30 ]; do echo line$i; i=$((i+1)); sleep 0.05; done`
	var want strings.Builder
	for i := range 30 {
		fmt.Fprintf(&want, "line%d\n", i)
	}
	fc.send(msg{"t": "exec", "id": 42, "ch": 1, "argv": []string{"sh", "-c", script}, "cwd": t.TempDir()})
	first := fc.collect(t, 1, collectOpts{stop: func(r *procResult) bool { return bytes.Count(r.out, []byte("\n")) >= 5 }})
	if first.exit != nil {
		t.Fatal("exited before the reconnect")
	}
	// Rail has stored the first five lines, then the connection goes.
	kept := uint64(bytes.Index(first.out, []byte("line4\n")) + len("line4\n"))
	fc.send(msg{"t": "ack", "ch": 1, "stream": 1, "offset": kept})
	fc.drop()

	fc2 := r.next(t)
	procs, _ := fc2.hello["procs"].([]any)
	if len(procs) != 1 {
		t.Fatalf("hello procs %v", fc2.hello["procs"])
	}
	p := msg(procs[0].(map[string]any))
	if p["id"] != float64(42) || p.num("out") < int64(kept) {
		t.Fatalf("hello proc %v", p)
	}
	if s := p.str("state"); s != "running" && s != "exited" {
		t.Fatalf("state %q", s)
	}

	// Rail numbers channels per connection; it resumes on a new one.
	fc2.send(msg{"t": "resume", "id": 42, "ch": 9, "out": kept, "err": 0})
	rest := fc2.collect(t, 9, collectOpts{out: kept})
	if got := string(first.out[:kept]) + string(rest.out); got != want.String() {
		t.Fatalf("got %q", got)
	}
	if rest.exit.num("code") != 0 {
		t.Fatalf("exit %v", rest.exit)
	}
}

func TestDoneRemovesSpool(t *testing.T) {
	r := newFakeRail(t)
	td := startDaemon(t, r, "")
	fc := r.next(t)
	fc.send(msg{"t": "exec", "id": 5, "ch": 1, "argv": []string{"echo", "hi"}, "cwd": t.TempDir()})
	fc.collect(t, 1, collectOpts{})
	dir := filepath.Join(td.state, "procs", "5")
	if _, err := os.Stat(dir); err != nil {
		t.Fatal(err)
	}
	fc.send(msg{"t": "done", "id": 5})
	waitFor(t, func() bool { _, err := os.Stat(dir); return os.IsNotExist(err) }, "spool removed")

	// The next hello no longer lists it.
	fc.drop()
	fc2 := r.next(t)
	if procs, _ := fc2.hello["procs"].([]any); len(procs) != 0 {
		t.Fatalf("hello procs %v", procs)
	}
}

func TestSignalGoesToTheGroup(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	fc.send(msg{"t": "exec", "id": 9, "ch": 1, "argv": []string{"sh", "-c", "sleep 30 & echo $!; wait"}, "cwd": t.TempDir()})
	first := fc.collect(t, 1, collectOpts{stop: func(r *procResult) bool { return bytes.HasSuffix(r.out, []byte("\n")) }})
	child, err := strconv.Atoi(strings.TrimSpace(string(first.out)))
	if err != nil {
		t.Fatal(err)
	}
	fc.send(msg{"t": "signal", "id": 9, "signal": "TERM"})
	res := fc.collect(t, 1, collectOpts{out: uint64(len(first.out))})
	if res.exit.num("code") != -1 || res.exit["signal"] != "TERM" {
		t.Fatalf("exit %v", res.exit)
	}
	waitFor(t, func() bool { return processGone(child) }, "the group's background sleep to die")
}

func TestVanishedProcessExitsMinusOne(t *testing.T) {
	state := shortTempDir(t)
	dir := filepath.Join(state, "procs", "77")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	// A pid that has certainly gone.
	gone := exec.Command("true")
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "spec.json"), []byte(`{"id":77,"argv":["x"]}`), 0o600)
	os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(gone.Process.Pid)), 0o600)
	os.WriteFile(filepath.Join(dir, "stdout"), []byte("partial"), 0o600)
	// A folder with no spec never started; it is dropped.
	os.MkdirAll(filepath.Join(state, "procs", "78"), 0o700)

	r := newFakeRail(t)
	startDaemon(t, r, state)
	fc := r.next(t)
	procs, _ := fc.hello["procs"].([]any)
	if len(procs) != 1 {
		t.Fatalf("hello procs %v", fc.hello["procs"])
	}
	p := msg(procs[0].(map[string]any))
	if p["id"] != float64(77) || p.str("state") != "exited" || p.num("out") != 7 {
		t.Fatalf("hello proc %v", p)
	}
	fc.send(msg{"t": "resume", "id": 77, "ch": 1, "out": 3, "err": 0})
	res := fc.collect(t, 1, collectOpts{out: 3})
	if string(res.out) != "tial" || res.exit.num("code") != -1 || res.exit["signal"] != nil {
		t.Fatalf("out %q exit %v", res.out, res.exit)
	}
	if _, err := os.Stat(filepath.Join(state, "procs", "78")); !os.IsNotExist(err) {
		t.Errorf("unstarted folder kept: %v", err)
	}
}

func TestAdoptsRunningProcessAfterRestart(t *testing.T) {
	state := shortTempDir(t)
	dir := filepath.Join(state, "procs", "88")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	// A process some earlier daemon started, still running.
	sleeper := exec.Command("sleep", "1")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	reaped := make(chan struct{})
	go func() { sleeper.Wait(); close(reaped) }()
	os.WriteFile(filepath.Join(dir, "spec.json"), []byte(`{"id":88,"argv":["sleep","1"]}`), 0o600)
	os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(sleeper.Process.Pid)), 0o600)

	r := newFakeRail(t)
	startDaemon(t, r, state)
	fc := r.next(t)
	procs, _ := fc.hello["procs"].([]any)
	if len(procs) != 1 || msg(procs[0].(map[string]any)).str("state") != "running" {
		t.Fatalf("hello procs %v", fc.hello["procs"])
	}
	fc.send(msg{"t": "resume", "id": 88, "ch": 1, "out": 0, "err": 0})
	res := fc.collect(t, 1, collectOpts{})
	<-reaped
	if res.exit.num("code") != -1 {
		t.Fatalf("exit %v", res.exit)
	}
	if _, err := os.Stat(filepath.Join(dir, "exit.json")); err != nil {
		t.Fatal(err)
	}
}

func TestOpenUnknownKind(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	fc.send(msg{"t": "open", "ch": 11, "kind": "devtools"})
	m := fc.waitMsg(t, "close")
	if m.num("ch") != 11 || m.str("error") != "unsupported" {
		t.Fatalf("close %v", m)
	}
}

func TestReadAndWriteCalls(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	dir := t.TempDir()
	target := filepath.Join(dir, "a", "b", "c.txt")
	fc.callOK(t, "write", map[string]any{"files": []any{map[string]any{"path": target, "data": b64("content"), "mode": 0o640}}})
	if b, err := os.ReadFile(target); err != nil || string(b) != "content" {
		t.Fatalf("%q %v", b, err)
	}
	if st, _ := os.Stat(target); st.Mode().Perm() != 0o640 {
		t.Errorf("mode %o", st.Mode().Perm())
	}
	res := fc.callOK(t, "read", map[string]any{"path": target})
	if res["data"] != b64("content") {
		t.Fatalf("read %v", res)
	}
	res = fc.callOK(t, "read", map[string]any{"path": filepath.Join(dir, "nope")})
	if res["missing"] != true {
		t.Fatalf("read missing %v", res)
	}
	if m := fc.call(t, "write", map[string]any{"files": []any{map[string]any{"path": "relative", "data": ""}}}); m["ok"] != false {
		t.Fatalf("relative write %v", m)
	}
	if m := fc.call(t, "nope", nil); m["ok"] != false || m.str("error") == "" {
		t.Fatalf("unknown method %v", m)
	}
}

func TestRunsAsCommandUser(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("switching users needs root")
	}
	r := newFakeRail(t)
	state := shortTempDir(t)
	os.Chmod(filepath.Dir(runnerBin), 0o755)
	startDaemon(t, r, state, func(c *config) { c.UID, c.GID = 65534, 65534 })
	fc := r.next(t)
	cwd := shortTempDir(t)
	os.Chmod(cwd, 0o777)
	fc.send(msg{"t": "exec", "id": 1, "ch": 1, "argv": []string{"sh", "-c", "id -u; id -g; cat f"}, "cwd": cwd,
		"files": []any{map[string]any{"path": "f", "data": b64("x")}}})
	res := fc.collect(t, 1, collectOpts{})
	if string(res.out) != "65534\n65534\nx" {
		t.Fatalf("out %q err %q", res.out, res.err)
	}
	st, _ := os.Stat(filepath.Join(cwd, "f"))
	if st.Sys().(*syscall.Stat_t).Uid != 65534 {
		t.Fatalf("file owner %d", st.Sys().(*syscall.Stat_t).Uid)
	}
}

// processGone is true once pid is gone or a zombie (where the tests run as
// PID 1, in a container, nobody reaps it).
func processGone(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return true
	}
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	_, rest, _ := strings.Cut(string(stat), ") ")
	return strings.HasPrefix(rest, "Z")
}

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// On the Mac the runner reaches Rail through rail-host's unix socket, whatever host the URL names.
func TestDialsThroughAUnixSocket(t *testing.T) {
	r := newFakeRail(t)
	// Short, since a unix socket's path is limited to about a hundred bytes.
	dir, err := os.MkdirTemp("/tmp", "rh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "s")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(r.serve)}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	startDaemon(t, r, "", func(c *config) {
		c.URL = "ws://rail-host/sandbox/socket"
		c.Socket = sock
	})
	if fc := r.next(t); fc.hello.str("runner") != "test" {
		t.Fatalf("hello %v", fc.hello)
	}
}

// An ordinary user, as on the Mac, keeps its state in its home folder, not in /var/lib.
func TestStateDirForAnOrdinaryUser(t *testing.T) {
	t.Setenv("RAIL_RUNNER_STATE", "/somewhere")
	if got := stateDir(); got != "/somewhere" {
		t.Fatalf("stateDir %q", got)
	}
	t.Setenv("RAIL_RUNNER_STATE", "")
	if os.Geteuid() == 0 {
		t.Skip("running as root")
	}
	home, _ := os.UserHomeDir()
	if got := stateDir(); got != filepath.Join(home, ".rail-runner") {
		t.Fatalf("stateDir %q", got)
	}
}

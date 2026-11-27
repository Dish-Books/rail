package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type config struct {
	URL          string
	Token        string
	AccessID     string
	AccessSecret string
	State        string
	UID, GID     int
	// Exe is the binary the shims in State/bin link to.
	Exe        string
	Version    string
	MinBackoff time.Duration
	MaxBackoff time.Duration
	Log        *log.Logger
	// A unix socket to reach URL through, as rail-host offers on the Mac; empty to dial URL itself.
	Socket string
}

const defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// stateDir is $RAIL_RUNNER_STATE, or a folder of the runner's own: /var/lib for
// root in a container, the home folder for an ordinary user, as on the Mac.
func stateDir() string {
	if dir := os.Getenv("RAIL_RUNNER_STATE"); dir != "" {
		return dir
	}
	if os.Geteuid() != 0 {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, ".rail-runner")
		}
	}
	return "/var/lib/rail-runner"
}

func configFromEnv() (config, error) {
	cfg := config{
		URL:          os.Getenv("RAIL_SANDBOX_URL"),
		Token:        os.Getenv("RAIL_SANDBOX_TOKEN"),
		AccessID:     os.Getenv("RAIL_ACCESS_CLIENT_ID"),
		AccessSecret: os.Getenv("RAIL_ACCESS_CLIENT_SECRET"),
		Socket:       os.Getenv("RAIL_SANDBOX_UNIX_SOCKET"),
		State:        stateDir(),
		UID:          1000,
		GID:          1000,
		Version:      version,
	}
	if cfg.URL == "" {
		return cfg, errors.New("RAIL_SANDBOX_URL is not set")
	}
	for _, v := range []struct {
		name string
		dst  *int
	}{{"RAIL_RUNNER_UID", &cfg.UID}, {"RAIL_RUNNER_GID", &cfg.GID}} {
		if s := os.Getenv(v.name); s != "" {
			n, err := strconv.Atoi(s)
			if err != nil || n < 0 {
				return cfg, fmt.Errorf("%s=%q is not a user id", v.name, s)
			}
			*v.dst = n
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return cfg, err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	cfg.Exe = exe
	return cfg, nil
}

type daemon struct {
	cfg config
	log *log.Logger

	mu    sync.Mutex
	procs map[string]*proc
	sess  *session // the welcomed session, or nil
	// sessChanged is closed and replaced whenever sess changes.
	sessChanged chan struct{}

	gitMu sync.Mutex // serializes checkout and sync
}

func newDaemon(cfg config) *daemon {
	if cfg.MinBackoff == 0 {
		cfg.MinBackoff = 500 * time.Millisecond
	}
	if cfg.MaxBackoff == 0 {
		cfg.MaxBackoff = 30 * time.Second
	}
	if cfg.Version == "" {
		cfg.Version = version
	}
	l := cfg.Log
	if l == nil {
		l = log.New(os.Stderr, "rail-runner: ", log.LstdFlags)
	}
	return &daemon{cfg: cfg, log: l, procs: map[string]*proc{}, sessChanged: make(chan struct{})}
}

func (d *daemon) procsDir() string { return filepath.Join(d.cfg.State, "procs") }
func (d *daemon) binDir() string   { return filepath.Join(d.cfg.State, "bin") }
func (d *daemon) sockPath() string { return filepath.Join(d.cfg.State, "runner.sock") }

// Run sets up the state folder and the unix socket, takes back the processes
// a previous run left, and keeps a connection to Rail until ctx ends.
// Commands keep running after it returns.
func (d *daemon) Run(ctx context.Context) error {
	if err := d.setup(); err != nil {
		return err
	}
	ln, err := d.listen()
	if err != nil {
		return err
	}
	go d.acceptLoop(ln)
	defer ln.Close()

	if err := d.adoptProcs(ctx); err != nil {
		return err
	}

	backoff := d.cfg.MinBackoff
	for ctx.Err() == nil {
		welcomed, err := d.connectOnce(ctx)
		if ctx.Err() != nil {
			break
		}
		if welcomed {
			backoff = d.cfg.MinBackoff
		}
		d.log.Printf("connection to Rail: %v", err)
		// Jitter: somewhere between half and all of the backoff.
		wait := backoff/2 + rand.N(backoff/2+1)
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
		backoff = min(backoff*2, d.cfg.MaxBackoff)
	}
	return ctx.Err()
}

func (d *daemon) setup() error {
	if err := os.MkdirAll(d.cfg.State, 0o755); err != nil {
		return err
	}
	// Commands must reach the socket and the shims in State, but not the spool.
	if err := os.Chmod(d.cfg.State, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(d.procsDir(), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(d.procsDir(), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(d.binDir(), 0o755); err != nil {
		return err
	}
	for _, name := range []string{remoteHelperName, signName} {
		link := filepath.Join(d.binDir(), name)
		tmp := link + ".tmp"
		_ = os.Remove(tmp)
		if err := os.Symlink(d.cfg.Exe, tmp); err != nil {
			return err
		}
		if err := os.Rename(tmp, link); err != nil {
			return err
		}
	}
	return nil
}

func (d *daemon) listen() (net.Listener, error) {
	_ = os.Remove(d.sockPath())
	ln, err := net.Listen("unix", d.sockPath())
	if err != nil {
		return nil, err
	}
	// Any user in the sandbox may use it.
	if err := os.Chmod(d.sockPath(), 0o666); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// cmdEnv is the environment for a command or the runner's own git: the
// daemon's own, less Rail's secrets, with extra applied and State/bin first on
// PATH.
func (d *daemon) cmdEnv(extra map[string]string) []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "RAIL_SANDBOX_TOKEN", "RAIL_SANDBOX_URL", "RAIL_SANDBOX_UNIX_SOCKET", "RAIL_ACCESS_CLIENT_ID", "RAIL_ACCESS_CLIENT_SECRET", childEnv:
			continue
		}
		env = append(env, kv)
	}
	env = envSet(env, "RAIL_RUNNER_STATE", d.cfg.State)
	if c := d.cred(); c != nil {
		if u, err := user.LookupId(strconv.Itoa(int(c.Uid))); err == nil {
			env = envSet(env, "HOME", u.HomeDir)
			env = envSet(env, "USER", u.Username)
			env = envSet(env, "LOGNAME", u.Username)
		}
	}
	for k, v := range extra {
		env = envSet(env, k, v)
	}
	path, ok := envGet(env, "PATH")
	if !ok || path == "" {
		path = defaultPath
	}
	return envSet(env, "PATH", d.binDir()+string(os.PathListSeparator)+path)
}

func (d *daemon) setSession(s *session) {
	d.mu.Lock()
	d.sess = s
	close(d.sessChanged)
	d.sessChanged = make(chan struct{})
	d.mu.Unlock()
}

func (d *daemon) clearSession(s *session) {
	d.mu.Lock()
	if d.sess == s {
		d.sess = nil
		close(d.sessChanged)
		d.sessChanged = make(chan struct{})
	}
	d.mu.Unlock()
}

// waitSession returns the welcomed session, waiting up to timeout for one
// while the runner reconnects.
func (d *daemon) waitSession(timeout time.Duration) *session {
	deadline := time.After(timeout)
	for {
		d.mu.Lock()
		s, changed := d.sess, d.sessChanged
		d.mu.Unlock()
		if s != nil && s.ctx.Err() == nil {
			return s
		}
		select {
		case <-changed:
		case <-deadline:
			return nil
		}
	}
}

// connectOnce dials Rail and serves one connection until it ends. welcomed
// reports whether Rail answered hello.
func (d *daemon) connectOnce(ctx context.Context) (welcomed bool, err error) {
	h := http.Header{}
	h.Set("X-Rail-Sandbox-Token", d.cfg.Token)
	h.Set("X-Rail-Runner", d.cfg.Version)
	if d.cfg.AccessID != "" {
		h.Set("CF-Access-Client-Id", d.cfg.AccessID)
	}
	if d.cfg.AccessSecret != "" {
		h.Set("CF-Access-Client-Secret", d.cfg.AccessSecret)
	}
	dialCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	opts := &websocket.DialOptions{HTTPHeader: h}
	if d.cfg.Socket != "" {
		// On the Mac, rail-host relays the socket and adds what Cloudflare asks for.
		opts.HTTPClient = &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", d.cfg.Socket)
			},
		}}
	}
	c, resp, err := websocket.Dial(dialCtx, d.cfg.URL, opts)
	cancel()
	if err != nil {
		if resp != nil && resp.Body != nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		return false, err
	}
	// Control messages (exec with files, sign) can be larger than a frame.
	c.SetReadLimit(256 << 20)
	s := newSession(ctx, d, c)
	return s.run()
}

func (d *daemon) acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go d.serveLocal(c.(*net.UnixConn))
	}
}

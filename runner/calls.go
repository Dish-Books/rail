package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// call runs one call and sends its reply on the session it came from.
func (d *daemon) call(s *session, m inMsg) {
	result, err := d.runCall(m.Method, m.Params)
	r := replyMsg{T: "reply", ID: m.ID, OK: err == nil}
	if err != nil {
		r.Error = err.Error()
	} else {
		r.Result = result
	}
	if err := s.sendJSON(r); err != nil {
		d.log.Printf("reply to %s: %v", m.Method, err)
	}
}

func (d *daemon) runCall(method string, raw json.RawMessage) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		raw = json.RawMessage("{}")
	}
	switch method {
	case "checkout":
		var p checkoutParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, fmt.Errorf("checkout params: %w", err)
		}
		d.gitMu.Lock()
		defer d.gitMu.Unlock()
		return d.checkout(p)
	case "sync":
		var p syncParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, fmt.Errorf("sync params: %w", err)
		}
		d.gitMu.Lock()
		defer d.gitMu.Unlock()
		return d.sync(p)
	case "write":
		var p struct {
			Path  string     `json:"path"`
			Files []fileSpec `json:"files"`
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, fmt.Errorf("write params: %w", err)
		}
		return struct{}{}, d.writeFilesAs(p.Path, p.Files)
	case "read":
		var p struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, fmt.Errorf("read params: %w", err)
		}
		data, missing, err := d.readFileAs(p.Path)
		if err != nil {
			return nil, err
		}
		if missing {
			return map[string]bool{"missing": true}, nil
		}
		return map[string]string{"data": base64.StdEncoding.EncodeToString(data)}, nil
	}
	return nil, fmt.Errorf("unknown method %q", method)
}

// git runs git as the command user in dir, on the command PATH (State/bin
// first, so git finds git-remote-rail and rail-sign) and with no prompts.
func (d *daemon) git(dir string, extraEnv map[string]string, args ...string) (string, error) {
	env := d.cmdEnv(nil)
	env = envSet(env, "GIT_TERMINAL_PROMPT", "0")
	for k, v := range extraEnv {
		env = envSet(env, k, v)
	}
	path, _ := envGet(env, "PATH")
	gitPath, err := lookPath("git", path)
	if err != nil {
		return "", err
	}
	cmd := exec.Command(gitPath, args...)
	cmd.Dir = dir
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: d.cred()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), firstNonEmpty(strings.TrimSpace(stderr.String()), err.Error()))
	}
	return strings.TrimSpace(stdout.String()), nil
}

type checkoutParams struct {
	Path   string         `json:"path"`
	Branch string         `json:"branch"`
	Config map[string]any `json:"config"`
	Files  []fileSpec     `json:"files"`
}

const (
	railURL      = "rail::task"
	wipRef       = "refs/rail/wip"
	originGlob   = "+refs/remotes/origin/*:refs/remotes/origin/*"
	receiptsSpec = "refs/ci-receipts/*:refs/ci-receipts/*"
)

func validBranch(b string) error {
	if b == "" || strings.HasPrefix(b, "-") || strings.ContainsAny(b, " ~^:?*[\\\x00") || strings.Contains(b, "..") {
		return fmt.Errorf("bad branch %q", b)
	}
	return nil
}

func (d *daemon) checkout(p checkoutParams) (any, error) {
	if !filepath.IsAbs(p.Path) {
		return nil, fmt.Errorf("path %q must be absolute", p.Path)
	}
	if err := validBranch(p.Branch); err != nil {
		return nil, err
	}
	created := false
	if _, err := os.Stat(filepath.Join(p.Path, ".git")); errors.Is(err, fs.ErrNotExist) {
		if err := d.clone(p.Path, p.Branch); err != nil {
			return nil, err
		}
		created = true
	} else if err != nil {
		return nil, err
	}

	keys := make([]string, 0, len(p.Config))
	for k := range p.Config {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := p.Config[k]
		var s string
		switch v := v.(type) {
		case string:
			s = v
		case nil:
			continue
		default:
			b, _ := json.Marshal(v)
			s = string(b)
		}
		if _, err := d.git(p.Path, nil, "config", k, s); err != nil {
			return nil, err
		}
	}
	// Files seed a new checkout only: on a disk that already has one they may
	// have been changed since, as an agent adds to its .env.
	if created {
		if err := d.writeFilesAs(p.Path, p.Files); err != nil {
			return nil, err
		}
	}
	return map[string]bool{"created": created}, nil
}

// clone makes path a checkout of rail::task on branch, with any work in
// progress Rail kept for it restored, uncommitted. It is git init and fetch
// rather than git clone so that it works in a folder that isn't empty (a
// fresh volume's mount point) and with Rail's refspec from the start.
func (d *daemon) clone(path, branch string) error {
	if err := d.prepareDir(path); err != nil {
		return err
	}
	steps := [][]string{
		{"init", "-q"},
		{"remote", "add", "origin", railURL},
		{"config", "remote.origin.fetch", originGlob},
	}
	for _, args := range steps {
		if _, err := d.git(path, nil, args...); err != nil {
			return err
		}
	}
	ls, err := d.git(path, nil, "ls-remote", "origin", "refs/heads/"+branch, wipRef)
	if err != nil {
		return err
	}
	remote := map[string]string{}
	for _, line := range strings.Split(ls, "\n") {
		if sha, ref, ok := strings.Cut(line, "\t"); ok {
			remote[ref] = sha
		}
	}
	fetch := []string{"fetch", "-q", "--no-tags", "origin", originGlob}
	head, hasHead := remote["refs/heads/"+branch]
	if hasHead {
		fetch = append(fetch, "refs/heads/"+branch)
	}
	wip, hasWip := remote[wipRef]
	if hasWip {
		fetch = append(fetch, wipRef)
	}
	if _, err := d.git(path, nil, fetch...); err != nil {
		return err
	}
	if !hasHead {
		head, err = d.git(path, nil, "rev-parse", "-q", "--verify", "refs/remotes/origin/"+branch+"^{commit}")
		if err != nil {
			return fmt.Errorf("branch %s is in neither refs/heads nor refs/remotes/origin of %s", branch, railURL)
		}
	}
	if _, err := d.git(path, nil, "checkout", "-q", "-B", branch, head); err != nil {
		return err
	}
	if hasWip {
		if _, err := d.git(path, nil, "checkout", wip, "--", "."); err != nil {
			return err
		}
		if _, err := d.git(path, nil, "reset", "-q"); err != nil {
			return err
		}
	}
	return nil
}

// prepareDir makes sure the checkout's folder exists and, when commands run
// as another user, that it belongs to them (a fresh volume's mount point is
// root's).
func (d *daemon) prepareDir(path string) error {
	c := d.cred()
	if c == nil {
		return os.MkdirAll(path, 0o755)
	}
	st, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		parent := filepath.Dir(path)
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return err
		}
		if err := os.Mkdir(path, 0o755); err != nil {
			return err
		}
		return os.Chown(path, int(c.Uid), int(c.Gid))
	}
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a folder", path)
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok && sys.Uid == 0 {
		return os.Chown(path, int(c.Uid), int(c.Gid))
	}
	return nil
}

type syncParams struct {
	Path   string `json:"path"`
	Branch string `json:"branch"`
}

func (d *daemon) sync(p syncParams) (any, error) {
	if !filepath.IsAbs(p.Path) {
		return nil, fmt.Errorf("path %q must be absolute", p.Path)
	}
	if err := validBranch(p.Branch); err != nil {
		return nil, err
	}
	head, err := d.git(p.Path, nil, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return nil, err
	}
	gitDir, err := d.git(p.Path, nil, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return nil, err
	}

	// The snapshot: HEAD's tree with the working tree added over it, in an
	// index of its own so the real one is untouched.
	index := filepath.Join(gitDir, "rail-wip-index")
	defer os.Remove(index)
	_ = os.Remove(index)
	idx := map[string]string{"GIT_INDEX_FILE": index}
	if _, err := d.git(p.Path, idx, "read-tree", "HEAD"); err != nil {
		return nil, err
	}
	if _, err := d.git(p.Path, idx, "add", "-A"); err != nil {
		return nil, err
	}
	tree, err := d.git(p.Path, idx, "write-tree")
	if err != nil {
		return nil, err
	}
	var ident map[string]string
	if email, _ := d.git(p.Path, nil, "config", "user.email"); email == "" {
		ident = map[string]string{
			"GIT_AUTHOR_NAME": "Rail", "GIT_AUTHOR_EMAIL": "rail@localhost",
			"GIT_COMMITTER_NAME": "Rail", "GIT_COMMITTER_EMAIL": "rail@localhost",
		}
	}
	wip, err := d.git(p.Path, ident, "commit-tree", "--no-gpg-sign", "-p", "HEAD", "-m", "Rail: uncommitted work", tree)
	if err != nil {
		return nil, err
	}

	if _, err := d.git(p.Path, nil, "push", "-q", "--force", "--no-verify", "origin",
		"HEAD:refs/heads/"+p.Branch, receiptsSpec, wip+":"+wipRef); err != nil {
		return nil, err
	}
	return map[string]string{"head": head, "wip": wip}, nil
}

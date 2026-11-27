package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// Hidden subcommands the daemon runs as the command user, so that files are
// written and read with that user's rights (a symlink in the checkout cannot
// make root write into the spool).
const (
	writeFilesCmd = "__write-files"
	readFileCmd   = "__read-file"
	exitMissing   = 3
)

type writeFilesReq struct {
	Base  string     `json:"base"`
	Files []fileSpec `json:"files"`
}

// writeFiles writes each file, making its folders. A relative path is taken
// from base; with no base it must be absolute.
func writeFiles(base string, files []fileSpec) error {
	for _, f := range files {
		p := f.Path
		if p == "" {
			return errors.New("file with no path")
		}
		if !filepath.IsAbs(p) {
			if base == "" {
				return fmt.Errorf("%s: relative path with no folder to take it from", p)
			}
			p = filepath.Join(base, p)
		}
		data, err := base64.StdEncoding.DecodeString(f.Data)
		if err != nil {
			return fmt.Errorf("%s: data is not base64: %w", f.Path, err)
		}
		mode := fs.FileMode(f.Mode) & fs.ModePerm
		if mode == 0 {
			mode = 0o644
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, data, mode); err != nil {
			return err
		}
		// WriteFile keeps an existing file's mode and is subject to umask.
		if err := os.Chmod(p, mode); err != nil {
			return err
		}
	}
	return nil
}

func writeFilesMain() int {
	var req writeFilesReq
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := writeFiles(req.Base, req.Files); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func readFileMain(path string) int {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return exitMissing
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	if _, err := io.Copy(os.Stdout, f); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

// cred is the credential commands run with: the configured user when
// the daemon runs as root, or nil to run as the daemon's own user.
func (d *daemon) cred() *syscall.Credential {
	if os.Geteuid() != 0 || d.cfg.UID == 0 {
		return nil
	}
	return &syscall.Credential{Uid: uint32(d.cfg.UID), Gid: uint32(d.cfg.GID), Groups: []uint32{uint32(d.cfg.GID)}}
}

// writeFilesAs writes files as the command user.
func (d *daemon) writeFilesAs(base string, files []fileSpec) error {
	if len(files) == 0 {
		return nil
	}
	if d.cred() == nil {
		return writeFiles(base, files)
	}
	req, err := json.Marshal(writeFilesReq{Base: base, Files: files})
	if err != nil {
		return err
	}
	cmd := exec.Command(d.cfg.Exe, writeFilesCmd)
	cmd.Args[0] = "rail-runner"
	cmd.Stdin = bytes.NewReader(req)
	cmd.Env = d.cmdEnv(nil)
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: d.cred()}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("writing files: %s", firstNonEmpty(strings.TrimSpace(stderr.String()), err.Error()))
	}
	return nil
}

// readFileAs reads a file as the command user. missing is true when there is
// no such file.
func (d *daemon) readFileAs(path string) (data []byte, missing bool, err error) {
	if !filepath.IsAbs(path) {
		return nil, false, fmt.Errorf("%s: path must be absolute", path)
	}
	if d.cred() == nil {
		data, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrNotExist) {
			return nil, true, nil
		}
		return data, false, err
	}
	cmd := exec.Command(d.cfg.Exe, readFileCmd, path)
	cmd.Args[0] = "rail-runner"
	cmd.Env = d.cmdEnv(nil)
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: d.cred()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) && ee.ExitCode() == exitMissing {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("reading %s: %s", path, firstNonEmpty(strings.TrimSpace(stderr.String()), err.Error()))
	}
	return stdout.Bytes(), false, nil
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

// lookPath finds name on the given PATH, the way a shell would, so a command
// is looked up on its own PATH rather than the daemon's.
func lookPath(name, path string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			dir = "."
		}
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s: not found on PATH", name)
}

func envGet(env []string, key string) (string, bool) {
	for i := len(env) - 1; i >= 0; i-- {
		if k, v, ok := strings.Cut(env[i], "="); ok && k == key {
			return v, true
		}
	}
	return "", false
}

func envSet(env []string, key, value string) []string {
	out := env[:0:0]
	for _, kv := range env {
		if k, _, _ := strings.Cut(kv, "="); k != key {
			out = append(out, kv)
		}
	}
	return append(out, key+"="+value)
}

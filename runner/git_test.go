package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return gitEnvT(t, dir, nil, args...)
}

func gitEnvT(t *testing.T, dir string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=Seed", "GIT_AUTHOR_EMAIL=seed@example.com",
		"GIT_COMMITTER_NAME=Seed", "GIT_COMMITTER_EMAIL=seed@example.com")
	cmd.Env = append(cmd.Env, env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeT(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readT(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// seedTaskRepo makes Rail's bare task repo: the task's branch "feature" and
// origin's main, as Rail would have fetched it.
func seedTaskRepo(t *testing.T) (bare, head string) {
	t.Helper()
	seed := t.TempDir()
	gitT(t, seed, "init", "-q")
	writeT(t, filepath.Join(seed, "a.txt"), "one\n")
	writeT(t, filepath.Join(seed, ".gitignore"), "*.log\n")
	gitT(t, seed, "add", ".")
	gitT(t, seed, "commit", "-q", "-m", "init")
	bare = filepath.Join(t.TempDir(), "task.git")
	gitT(t, "", "init", "-q", "--bare", bare)
	gitT(t, seed, "push", "-q", bare, "HEAD:refs/heads/feature", "HEAD:refs/remotes/origin/main")
	return bare, gitT(t, seed, "rev-parse", "HEAD")
}

func TestCheckoutAndSync(t *testing.T) {
	r := newFakeRail(t)
	bare, seedHead := seedTaskRepo(t)
	r.bare = bare
	startDaemon(t, r, "")
	fc := r.next(t)

	work := filepath.Join(t.TempDir(), "task")
	config := map[string]any{"user.name": "Owner", "user.email": "owner@example.com"}
	res := fc.callOK(t, "checkout", map[string]any{
		"path": work, "branch": "feature", "config": config,
		"files": []any{map[string]any{"path": ".rail/brief.md", "data": b64("the brief")}},
	})
	if res["created"] != true {
		t.Fatalf("checkout %v", res)
	}
	if got := gitT(t, work, "rev-parse", "HEAD"); got != seedHead {
		t.Fatalf("HEAD %s, want %s", got, seedHead)
	}
	if got := gitT(t, work, "symbolic-ref", "--short", "HEAD"); got != "feature" {
		t.Fatalf("branch %s", got)
	}
	if got := gitT(t, work, "rev-parse", "refs/remotes/origin/main"); got != seedHead {
		t.Fatalf("origin/main %s", got)
	}
	if got := gitT(t, work, "config", "remote.origin.url"); got != "rail::task" {
		t.Fatalf("origin %s", got)
	}
	if got := gitT(t, work, "config", "--get-all", "remote.origin.fetch"); got != "+refs/remotes/origin/*:refs/remotes/origin/*" {
		t.Fatalf("refspec %s", got)
	}
	if got := gitT(t, work, "config", "user.email"); got != "owner@example.com" {
		t.Fatalf("user.email %s", got)
	}
	if got := readT(t, filepath.Join(work, ".rail/brief.md")); got != "the brief" {
		t.Fatalf("brief %q", got)
	}

	// Work: a commit, then uncommitted changes, an untracked file, an ignored
	// file and a CI receipt.
	writeT(t, filepath.Join(work, "b.txt"), "committed\n")
	gitT(t, work, "add", "b.txt")
	gitT(t, work, "commit", "-q", "-m", "b")
	head := gitT(t, work, "rev-parse", "HEAD")
	writeT(t, filepath.Join(work, "a.txt"), "one\ntwo\n")
	writeT(t, filepath.Join(work, "new.txt"), "untracked\n")
	writeT(t, filepath.Join(work, "debug.log"), "ignored\n")
	gitT(t, work, "update-ref", "refs/ci-receipts/"+head, head)
	statusBefore := gitT(t, work, "status", "--porcelain")

	res = fc.callOK(t, "sync", map[string]any{"path": work, "branch": "feature"})
	if res["head"] != head {
		t.Fatalf("sync head %v, want %s", res["head"], head)
	}
	wip, _ := res["wip"].(string)
	if got := gitT(t, bare, "rev-parse", "refs/heads/feature"); got != head {
		t.Fatalf("pushed branch %s", got)
	}
	if got := gitT(t, bare, "rev-parse", "refs/rail/wip"); got != wip {
		t.Fatalf("pushed wip %s, want %s", got, wip)
	}
	if got := gitT(t, bare, "rev-parse", "refs/ci-receipts/"+head); got != head {
		t.Fatalf("receipt %s", got)
	}
	if got := gitT(t, bare, "rev-parse", wip+"^"); got != head {
		t.Fatalf("wip parent %s", got)
	}
	files := gitT(t, bare, "ls-tree", "-r", "--name-only", wip)
	if !strings.Contains(files, "new.txt") || strings.Contains(files, "debug.log") || !strings.Contains(files, "b.txt") {
		t.Fatalf("wip files:\n%s", files)
	}
	if got := gitT(t, bare, "show", wip+":a.txt"); got != "one\ntwo" {
		t.Fatalf("wip a.txt %q", got)
	}
	if got := gitT(t, work, "status", "--porcelain"); got != statusBefore {
		t.Fatalf("sync touched the index:\n%s\nwas\n%s", got, statusBefore)
	}

	// Again on the same folder: no clone, config still applied, and the files
	// left as they were changed.
	writeT(t, filepath.Join(work, ".rail/brief.md"), "changed")
	config["user.name"] = "Owner Two"
	res = fc.callOK(t, "checkout", map[string]any{
		"path": work, "branch": "feature", "config": config,
		"files": []any{map[string]any{"path": ".rail/brief.md", "data": b64("the brief")}},
	})
	if res["created"] != false {
		t.Fatalf("second checkout %v", res)
	}
	if got := gitT(t, work, "config", "user.name"); got != "Owner Two" {
		t.Fatalf("user.name %s", got)
	}
	if got := readT(t, filepath.Join(work, ".rail/brief.md")); got != "changed" {
		t.Fatalf("second checkout rewrote a file: %q", got)
	}
	if got := readT(t, filepath.Join(work, "a.txt")); got != "one\ntwo\n" {
		t.Fatalf("second checkout changed the work: %q", got)
	}

	// A fresh disk gets the branch with the work restored, uncommitted.
	work2 := filepath.Join(t.TempDir(), "task")
	res = fc.callOK(t, "checkout", map[string]any{"path": work2, "branch": "feature", "config": config})
	if res["created"] != true {
		t.Fatalf("fresh checkout %v", res)
	}
	if got := gitT(t, work2, "rev-parse", "HEAD"); got != head {
		t.Fatalf("fresh HEAD %s, want %s", got, head)
	}
	if got := readT(t, filepath.Join(work2, "a.txt")); got != "one\ntwo\n" {
		t.Fatalf("restored a.txt %q", got)
	}
	if got := readT(t, filepath.Join(work2, "new.txt")); got != "untracked\n" {
		t.Fatalf("restored new.txt %q", got)
	}
	// .rail/ came with checkout's files, untracked, so it is part of the work.
	if got := gitT(t, work2, "status", "--porcelain"); got != "M a.txt\n?? .rail/\n?? new.txt" {
		t.Fatalf("restored status:\n%s", got)
	}

	// A sync with no receipts to push works too.
	res = fc.callOK(t, "sync", map[string]any{"path": work2, "branch": "feature"})
	if res["head"] != head {
		t.Fatalf("second sync %v", res)
	}
}

func TestCheckoutMissingBranch(t *testing.T) {
	r := newFakeRail(t)
	r.bare, _ = seedTaskRepo(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	m := fc.call(t, "checkout", map[string]any{"path": filepath.Join(t.TempDir(), "x"), "branch": "nope"})
	if m["ok"] != false || !strings.Contains(m.str("error"), "nope") {
		t.Fatalf("reply %v", m)
	}
	// It may come from refs/remotes/origin when Rail has no refs/heads yet.
	res := fc.callOK(t, "checkout", map[string]any{"path": filepath.Join(t.TempDir(), "y"), "branch": "main"})
	if res["created"] != true {
		t.Fatalf("checkout main %v", res)
	}
}

func TestSignedCommit(t *testing.T) {
	r := newFakeRail(t)
	r.bare, _ = seedTaskRepo(t)
	keyDir := t.TempDir()
	r.key = filepath.Join(keyDir, "owner")
	if out, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "owner", "-f", r.key).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v %s", err, out)
	}
	pub := strings.TrimSpace(readT(t, r.key+".pub"))
	td := startDaemon(t, r, "")
	fc := r.next(t)

	work := filepath.Join(t.TempDir(), "task")
	fc.callOK(t, "checkout", map[string]any{"path": work, "branch": "feature", "config": map[string]any{
		"user.name": "Owner", "user.email": "owner@example.com",
		"gpg.format": "ssh", "gpg.ssh.program": "rail-sign",
		"user.signingkey": "key::" + pub, "commit.gpgsign": "true",
	}})

	fc.send(msg{"t": "exec", "id": 1, "ch": 1, "argv": []string{"git", "commit", "-q", "--allow-empty", "-m", "signed"}, "cwd": work})
	res := fc.collect(t, 1, collectOpts{})
	if res.exit.num("code") != 0 {
		t.Fatalf("git commit: exit %v\n%s%s", res.exit, res.out, res.err)
	}
	if raw := gitT(t, work, "cat-file", "commit", "HEAD"); !strings.Contains(raw, "gpgsig -----BEGIN SSH SIGNATURE-----") {
		t.Fatalf("commit is not signed:\n%s", raw)
	}

	// Verify with the repo's own gpg.ssh.program, rail-sign, which hands
	// verification to ssh-keygen.
	allowed := filepath.Join(keyDir, "allowed_signers")
	writeT(t, allowed, "owner@example.com "+pub+"\n")
	env := []string{
		"PATH=" + filepath.Join(td.state, "bin") + string(os.PathListSeparator) + os.Getenv("PATH"),
		"RAIL_RUNNER_STATE=" + td.state,
	}
	gitEnvT(t, work, env, "-c", "gpg.ssh.allowedSignersFile="+allowed, "verify-commit", "HEAD")

	// Another key's allowed signers don't verify it.
	other := filepath.Join(keyDir, "other")
	exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other).Run()
	writeT(t, allowed, "owner@example.com "+strings.TrimSpace(readT(t, other+".pub"))+"\n")
	cmd := exec.Command("git", "-c", "gpg.ssh.allowedSignersFile="+allowed, "verify-commit", "HEAD")
	cmd.Dir = work
	cmd.Env = append(os.Environ(), env...)
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("verified with the wrong key:\n%s", out)
	}
}

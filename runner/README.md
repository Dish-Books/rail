# rail-runner

The process inside every Rail sandbox. It holds one WebSocket to Rail and runs the task's commands and git for it. The design and the wire protocol are in [`docs/sandbox-socket.md`](../docs/sandbox-socket.md); this file covers building it and the choices the spec left open.

## Build and test

Go comes from the repo's `mise.toml` (`mise exec -- make ...` if `go` isn't on your PATH).

```sh
make build   # CGO_ENABLED=0 static binaries: dist/{linux-amd64,linux-arm64,darwin-arm64}/rail-runner
make test    # gofmt -l, go vet, go test -race ./...
```

`VERSION=...` sets the version the runner reports (`-X main.version`, default `git describe`, `dev` without ldflags).

The tests run the daemon in-process against a fake Rail (`fake_rail_test.go`: `httptest` plus `coder/websocket`) that serves git channels with a real `git upload-pack`/`receive-pack` on a bare repo and signs with a throwaway `ssh-keygen` key. `TestMain` builds the real binary so `git-remote-rail` and `rail-sign` run for real. They need `git` and `ssh-keygen` on PATH. The uid switch is tested only as root; to run the tests as root on Linux, cross-compile them (`GOOS=linux go test -c`, plus `go build`), and run the test binary in a container with `RAIL_RUNNER_TEST_BIN` pointing at the built runner. `RUNNER_TEST_LOG=1` shows the daemon's log.

## One binary, three names

By the basename of `argv[0]`:

| Name | What it is |
|---|---|
| `rail-runner` | The daemon. As PID 1 it starts itself again as a child and stays as a minimal init (see Choices). |
| `git-remote-rail` | Git's remote helper for `rail::` URLs. Offers only `connect`; hands the connection to the daemon over `$RAIL_RUNNER_STATE/runner.sock`. |
| `rail-sign` | Git's `gpg.ssh.program`. `-Y sign` goes to Rail through the daemon; anything else (`verify`, `find-principals`, `check-novalidate`) is passed to the real `ssh-keygen`. |

On start the daemon links the other two names to itself in `$RAIL_RUNNER_STATE/bin` and puts that folder first on `PATH` for every command and for its own git.

`$RAIL_RUNNER_STATE` (default `/var/lib/rail-runner` as root, `~/.rail-runner` as an ordinary user such as a Mac task's; mode 0755):

```
bin/                git-remote-rail, rail-sign -> the binary
runner.sock         0666: any user may connect
procs/              0700, root's: commands can't read or touch the spool
  <id>/spec.json    the exec (argv, env, cwd, stderr, oom_before; no file contents or stdin)
  <id>/stdin        decoded stdin, when there was one
  <id>/stdout       the command's stdout (and stderr with "merge")
  <id>/stderr
  <id>/pid
  <id>/exit.json    {code, signal, oom}
```

## Choices

Where `docs/sandbox-socket.md` left something open, this is the reading taken.

**Ids and messages**

- A process `id` is echoed back exactly as Rail sent it, number or string; its folder is its text form. An id that can't name a folder gets `close` on the exec's channel.
- `exit.signal` is `null` unless a signal killed the process, and then a name without `SIG` (`"TERM"`, `"KILL"`, ...). `oom` is `false` when `memory.events` can't be read (any non-Linux host).
- Before `exit`, the runner sends `eof` on streams 1 and 2 of the channel. `exit` goes out once both files are read to their end and sent (not acked), with those ends as `out`/`err`.
- A command that can't start (not on its PATH, bad cwd, files that can't be written) still settles: its reason goes on stderr, it exits with code 127, and there is no `started`.
- `exec` for a known id is ignored, channel included: Rail gets that process with `resume`.
- `resume` for an unknown id is answered with `close` and `"error": "unknown process"`.
- `close` from Rail on a proc channel stops sending; the process keeps running.
- `done` on a process still running kills its group first, then removes the folder.
- `sign` ids are integers counted per connection. `signature` is the armored text `ssh-keygen -Y sign` writes to `.sig`, and `rail-sign` writes it verbatim (adding a final newline if missing).
- The `close` the runner sends carries `error` only; `code` is left out.

**Connections**

- Pings are WebSocket ping frames every `ping_ms`. One unanswered within `max(ping_ms, 5 s)` drops the connection and the runner reconnects.
- Backoff is jittered between half and all of the current step (0.5 s doubling to 30 s), and resets after a connection Rail welcomed.
- `hello` is written before anything else on a connection. Shims (git, sign) are served only once Rail has sent `welcome`, and wait up to 30 s for one while the runner reconnects; a sign waits up to 2 minutes for `signed`.
- Calls answer on the connection they came in on; if it's gone, the reply is dropped. `checkout` and `sync` run one at a time; `read` and `write` don't wait for them.
- Control messages may be up to 256 MiB (exec with files); binary frames are checked against the 64 KiB limit.
- The writer gives control messages priority. Each channel hands it one frame at a time on one unbuffered Go channel, whose blocked senders are served in order, so channels take turns.

**Git channels and shims**

- `git-remote-rail` prints git's blank line once it has connected to the daemon's socket and sent its line. The socket has no reply for `git`; if Rail can't be reached the daemon closes it and git reports the error. `option` lines get `unsupported`.
- Bytes are acked once written to the shim, at least every quarter window and whenever the queue empties. Frames sent twice are trimmed by offset; a gap closes the channel with `"missing bytes"`.
- The shim half-closing becomes `eof`; Rail's `eof` half-closes the socket, and Rail's `close` closes it once everything before it is written. The runner sends `close` itself only when the shim goes away first.

**Commands and the runner's git**

- A command's environment is the daemon's own minus `RAIL_SANDBOX_TOKEN`, `RAIL_SANDBOX_URL`, `RAIL_SANDBOX_UNIX_SOCKET` and `RAIL_ACCESS_CLIENT_*`, plus `RAIL_RUNNER_STATE` (the shims need it), then `HOME`/`USER`/`LOGNAME` from `/etc/passwd` when switching users, then the exec's `env`, and finally `$RAIL_RUNNER_STATE/bin` put first on `PATH`. The runner's own git gets the same, plus `GIT_TERMINAL_PROMPT=0`.
- `argv[0]` is looked up on the command's own `PATH`. A relative path in `files` is taken from `cwd`.
- `files`, `write` and `read` run as the command user through hidden subcommands of the binary (`__write-files`, `__read-file`), so a symlink in the checkout can't make root write or read somewhere else. When the daemon already runs as that user they run in-process.
- `write` paths must be absolute, or relative to an optional `path` param. Files are written with `mode` (default 0644) and get any missing folders (0755). `mode` may be a number or an octal string. `read` takes an absolute path.
- `oom` compares `oom_kill` with the value before the start, which is kept in `spec.json` so it survives a daemon restart.
- A process the daemon finds in `procs/` with no `exit.json` is polled by pid every 250 ms; when it's gone, or already gone at start, it gets `exit.json` with code -1 and signal `null`. A folder with no `spec.json` never started, and is removed, so Rail's next `exec` runs it.
- **PID 1.** As a container's entrypoint the runner is PID 1 and inherits orphaned processes. It can't reap them with `wait4(-1)` without stealing its commands' exit statuses, so PID 1 runs as a small init: it starts the daemon as its child (`RAIL_RUNNER_CHILD=1`), forwards signals to it, reaps everything, and restarts the daemon if it dies after running at least 10 s. Docker's `--init` isn't needed.

**Calls**

- `checkout` clones only when `path` has no `.git`. It uses `git init`, `remote add origin rail::task`, the `+refs/remotes/origin/*:refs/remotes/origin/*` refspec, `ls-remote`, then one `fetch`, rather than `git clone`. That works in a mount point that isn't empty and never fetches with git's default refspec. The branch comes from `refs/heads/<branch>` in Rail's repo, or failing that from `refs/remotes/origin/<branch>`. Otherwise the call fails.
- `refs/rail/wip` is restored (`git checkout <wip> -- .`, `git reset -q`) only on that first checkout. When `.git` already exists, `checkout` changes neither the branch nor the files and only sets `config`, so neither an older snapshot nor its `files` overwrite what is on the disk.
- `checkout` sets `config` keys in sorted order. A string is set as is, a `null` is skipped, and any other JSON value is set as its JSON text. Its `files` are relative to `path`. As root it gives the folder at `path` to the command user if root owns it (a fresh volume's mount point).
- `sync` always makes the wip snapshot, even with nothing uncommitted (its tree is then `HEAD`'s). Its temporary index is `.git/rail-wip-index`. If the checkout has no `user.email`, the snapshot commit is made as `Rail <rail@localhost>`. It pushes with `--no-verify`, so the project's pre-push hooks don't run, in one `git push --force origin HEAD:refs/heads/<branch> refs/ci-receipts/*:refs/ci-receipts/* <wip>:refs/rail/wip`.

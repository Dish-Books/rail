# Sandboxes over one socket (RAIL-227)

Each sandbox runs `rail-runner`, which holds one WebSocket to Rail and reaches Rail over nothing else. The same binary runs in a Docker container on Rail's host, as a macOS user of its own on the Mac mini, and later in a k8s pod. This file is the design and the wire protocol; the plan it belongs to is "Rail sandboxes over an API".

## What a sandbox is

A sandbox is a task's **disk** and, while the task has work, its **compute**.

- **The disk** holds the task's checkout, `deps`, `_build` and all, so a sandbox comes back in seconds without running setup again. On Rail's Docker host it is a Docker volume, `rail-sandbox-<sandbox id>`, mounted at the task's `worktree_path`; on the Mac, the home folder of the task's own macOS user; in k8s, a PersistentVolumeClaim. It lives until the task's checkout is removed.
- **The compute** is a container (on the Mac, the task's user's processes; in k8s, a pod) running `rail-runner`. Rail starts it when one of the task's commands is admitted and stops it once the task has had nothing running for `idle_minutes` (2 by default; Boot looks once a minute, so it is 2 to 3 in practice). A restart is a new container, the runner's hello and a checkout that finds the disk already has one: seconds. Whatever the agent left running stops with it, as a turn's brief already says.
- Every command still gets its own `OsProcess` row, under the task's `sandboxes` row.

**Capacity.** Each command still reserves its role's CPUs while it runs, and the line admits oldest first, as now. Those reservations are what bound how many containers run at once, and an idle one stops after `idle_minutes`. A host that needs a hard cap as well sets `RAIL_MAX_SANDBOXES`: a command whose task has no running container then waits for a slot, and idle containers give theirs up first. The container's CPU shares are the sum of what its running commands reserve.

**No account's login** is in a sandbox (RAIL-228). Claude Code runs with `ANTHROPIC_BASE_URL` at the runner, which carries each request over the socket to Rail's Claude proxy (below), and Rail adds the credential of the account the turn was placed on. So turns on different accounts share one container, and only Rail refreshes a login.

**What is no longer mounted:** the checkout (now the volume), the project's clone, the account's login, and the mise folder (a read-only `rail-mise` Docker volume instead, for projects with no image of their own). The task's scratch folder stays mounted until the rest of RAIL-228 moves shared state. Triage, support and curator passes (`Rail.Tools.run_agent/3`) keep their read-only mounts and their account's login until they move into sandboxes of their own.

## The runner

**Go**, one module in `runner/`, built with `CGO_ENABLED=0` for `linux/amd64`, `linux/arm64` and `darwin/arm64`: a static binary with no runtime to install.

- Rust would also give one static binary, but builds slower and asks more of whoever maintains it, and nothing here needs what it adds. An Elixir release carries ERTS per platform and puts a second BEAM in every sandbox.
- One dependency, `github.com/coder/websocket`; the rest is the standard library.
- It serves HTTP on a loopback port of the sandbox's own (`RAIL_RUNNER_HTTP`, a free port by default): `/v1/*` for Claude Code and `/mcp` for Rail's MCP server, each request carried over a channel (below).
- One binary, several names by `argv[0]`: `rail-runner` the daemon, `git-remote-rail` the remote helper, `rail-sign` the `gpg.ssh.program`. The daemon links the other two into `$RAIL_RUNNER_STATE/bin` and puts that first on every command's `PATH`.
- In a container it runs as root and runs every command, and its own git, as `RAIL_RUNNER_UID:RAIL_RUNNER_GID` (1000:1000), so a command cannot touch its spool. Started as an ordinary user, as on the Mac, it runs everything as that user and assumes no root, Linux path or container filesystem: its state folder and every path come from its environment.
- As a container's entrypoint it is PID 1: it reaps orphans, forwards signals, and starts the daemon again if it dies, so the container needs no init of Docker's.
- CI gets a `runner` lane: `gofmt -l`, `go vet`, `go test -race ./...`. `mise.toml` pins Go.
- Rail puts the binary into whatever image a sandbox uses before starting it, with Docker's `PUT /containers/{id}/archive` at `/opt/rail/rail-runner`, and makes it the entrypoint. The image needs nothing of Rail's. Rail's own image carries the binaries for `linux/amd64` and `linux/arm64` at `/app/runner/`. On the Mac, `rail-host` installs the `darwin/arm64` build and starts it as the task's user (RAIL-230).

### The runner's environment

| Variable | |
|---|---|
| `RAIL_SANDBOX_URL` | `ws://localhost:4000/sandbox/socket` on Rail's host; in-cluster, the service's private address |
| `RAIL_SANDBOX_UNIX_SOCKET` | a unix socket to reach `RAIL_SANDBOX_URL` through: on the Mac, the one `rail-host` relays to Rail |
| `RAIL_SANDBOX_TOKEN` | this container's token |
| `RAIL_ACCESS_CLIENT_ID`, `RAIL_ACCESS_CLIENT_SECRET` | a Cloudflare Access service token, only where the runner itself goes through Cloudflare; on the Mac `rail-host` adds them and only root can read them |
| `RAIL_RUNNER_STATE` | its own folder: by default `/var/lib/rail-runner` as root in a container, `~/.rail-runner` as an ordinary user |
| `RAIL_RUNNER_UID`, `RAIL_RUNNER_GID` | who commands run as, default 1000 |
| `RAIL_RUNNER_HTTP` | the address its HTTP listener takes, default `127.0.0.1:0` |

Every command gets `RAIL_MCP_URL`, the listener's `/mcp`. A command whose `exec` says `claude` also gets `ANTHROPIC_BASE_URL`, the listener, and `CLAUDE_CODE_OAUTH_TOKEN`, a random token the runner made for that process alone. The token names the process to the runner, which keeps it in the process's spool so a restarted daemon still knows it, and is worth nothing anywhere else. It goes when Rail sends `done`.

## The wire protocol

One WebSocket: `GET /sandbox/socket`, with `X-Rail-Sandbox-Token: <token>` and `X-Rail-Runner: <version>`, plus `CF-Access-Client-Id` and `CF-Access-Client-Secret` when set. Rail refuses an unknown token before upgrading. The token is random, made each time a container is, and kept only as its SHA-256 on the sandbox row, the way the MCP run token is. It names one sandbox, so one task.

**Text frames** are JSON control messages, `{"t": "<type>", ...}`. **Binary frames** carry a channel's bytes:

```
| channel: u32 | stream: u8 | offset: u64 | payload |    big-endian, 13-byte header, payload at most 64 KiB
```

`stream` is 0 for a channel's one stream, or a process's 1 (stdout) and 2 (stderr). `offset` is where the payload starts in that stream, counted from the stream's start, so a frame sent twice, after a reconnect, is recognised and its old part dropped.

### Channels

A channel is a byte stream in each direction. Rail numbers the channels it opens odd and the runner even. Numbers last one connection; what outlives a reconnect is named by its own id (an `os_process_id`).

| Kind | Opened by | Carries |
|---|---|---|
| `proc` | Rail, with `exec` or `resume` | a command's stdout (1) and stderr (2) |
| `git` | runner, for `git-remote-rail` | `git-upload-pack` or `git-receive-pack` against Rail's repo for the task, stream 0 both ways |
| `claude` | runner, for a request to its HTTP listener's `/v1/*` | one HTTP request and its answer (below) |
| `mcp` | runner, for a request to its HTTP listener's `/mcp` | the same |
| `devtools` | runner | reserved for RAIL-228; Rail answers `close` with `"error": "unsupported"` |

### Control messages

Runner to Rail:

| `t` | Fields | |
|---|---|---|
| `hello` | `runner`, `os`, `arch`, `procs: [{id, state: "running" \| "exited", out, err}]` | first, on every connection; `out`/`err` are the spool's sizes |
| `started` | `id`, `pid` | |
| `exit` | `id`, `code`, `signal`, `oom`, `out`, `err` | `code` is -1 when killed by `signal` (`"KILL"`); `oom` when the sandbox's cgroup killed something for memory meanwhile; `out`/`err` the final sizes |
| `open` | `ch`, `kind`; for `git` `service: "git-upload-pack" \| "git-receive-pack"`; for `claude` and `mcp` `method`, `path`, `headers: {name: [values]}`, and for `claude` `proc`, the process whose token the request carried | |
| `sign` | `id`, `payload` (base64) | a commit or tag to sign |
| `reply` | `id`, `ok`, `result` or `error` | the answer to a `call` |

Rail to runner:

| `t` | Fields | |
|---|---|---|
| `welcome` | `window`, `ping_ms` | after `hello` |
| `exec` | `id`, `ch`, `argv`, `env`, `cwd`, `files: [{path, data, mode}]`, `stdin`, `stderr: "merge" \| "separate"`, `claude` | `data` and `stdin` base64; `files` are written, as the command's user, before it starts; `claude: true` gives the command a token for the Claude proxy; known ids are ignored |
| `head` | `ch`, `status`, `headers: {name: [values]}` | the answer to an HTTP channel's request, before its body |
| `resume` | `id`, `ch`, `out`, `err` | send process `id` on `ch` again from these offsets |
| `done` | `id` | settled: its spool may go |
| `signal` | `id`, `signal: "TERM" \| "KILL"` | to the process's group |
| `signed` | `id`, `signature` or `error` | the answer to `sign` |
| `call` | `id`, `method`, `params` | see below |

Either way:

| `t` | Fields | |
|---|---|---|
| `ack` | `ch`, `stream`, `offset` | everything before `offset` is safe with the receiver |
| `eof` | `ch`, `stream` | the sender will write no more on that stream |
| `close` | `ch`, `error`, `code` | the channel is over |

### Calls

| `method` | `params` | Does, in the sandbox |
|---|---|---|
| `checkout` | `path`, `branch`, `config`, `files` | Clones `rail::task` into `path` if it holds no `.git`, with `origin` as that URL and `+refs/remotes/origin/*:refs/remotes/origin/*` as its fetch refspec, and checks out `branch`, restoring `refs/rail/wip` over it when Rail has one. Writes `files` only then, so a later connection never undoes a change to them; sets each `config` key with `git config` every time. Returns `{created}`. |
| `sync` | `path`, `branch` | Pushes `HEAD` to `refs/heads/<branch>`, `refs/ci-receipts/*`, and a snapshot of uncommitted work (tracked and untracked, ignored left out, built with a temporary index) to `refs/rail/wip`, all forced. Returns `{head, wip}`. |
| `write` | `files` | Writes files, as the command's user, making their folders. |
| `read` | `path` | Returns `{data}` (base64), or `{missing: true}` when there is no such file. |

### HTTP channels

The runner forwards a request's `method`, `path` and an allowlist of headers (no cookies, nothing hop-by-hop) in `open`, its body on stream 0, then `eof`. Rail answers with `head`, the body on stream 0, then `close` with no `error`. A `close` with an `error` before `head` is answered to the caller as a 502 carrying that error; one after it cuts the body short. The runner writes and flushes each frame as it comes, so a server-sent stream reaches Claude Code as Claude sends it.

- **`claude`**: Rail forwards only `POST /v1/messages` and `/v1/messages/count_tokens`, only for an agent process running in this sandbox whose token the runner vouched for, to `api.anthropic.com` with the OAuth token of the account the turn was placed on (`Rail.Tools.SandboxProxy`, `Rail.Tools.Claude.access_token/1`). A token about to expire is refreshed first by running the CLI beside Rail; a 401 is answered by refreshing once and asking again. Anything else gets a 403 or 401 in Claude's error shape. Claude Code runs with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`: with it, the pinned version (2.1.330) sends nothing but messages, and all of them to its base URL; without it, it also calls feature flags, its bootstrap, event logging and a server list on `api.anthropic.com` directly. Its own retries on 5xx and 529 go through the proxy like any request.
- **`mcp`**: Rail's MCP server answers it (`Rail.Mcp.handle_rpc/2`, as `/mcp/internal` does for an agent beside Rail), for a run token whose process runs in this sandbox.

**Claude's config and transcripts.** An agent's `CLAUDE_CONFIG_DIR` is `/tmp/rail-claude`, in the container. Its `exec` writes `.claude.json` there, trusting the checkout, and, for a turn that resumes a conversation, the conversation's transcript at the path the CLI reads for the checkout (`Backend.sandbox_session_dir/1`). After each turn the Follower reads the transcript back with `read` and keeps it in the account's session folder (`Backend.session_dir/2`, RAIL-219), where the next turn on that account takes it from. A new container on the same disk resumes with it.

### Flow control

Per stream and per direction, a sender may have at most `window` bytes (1 MiB) sent past the receiver's last `ack`. The receiver acks once what it got is safe: process output once the batch is committed to Postgres, so the ack is also the durability point. It acks at least every quarter window. The runner's writer takes frames from channels in turn, so a chatty CI run never holds up a push.

### Heartbeats and reconnects

- The runner pings every `ping_ms` (20 s); Cloudflare closes a WebSocket idle for 100 s. Rail closes a socket it has heard nothing on for 60 s.
- The runner reconnects with jittered backoff, 0.5 s doubling to 30 s, for as long as it lives. Commands keep running meanwhile.
- On every connection it sends `hello` with every process it holds. For each, Rail sends `resume` from what it has, `signal` and `done` for one Rail has settled, or, for one it never heard of, nothing. A process Rail expected but `hello` lacks gets its `exec` again.

### Durability

The runner starts each command with its stdout and stderr going straight to files in `$RAIL_RUNNER_STATE/procs/<id>/`, and reads them back to send them, so a command never waits on the socket. It records the exit in `exit.json` there. The spool stays until `done`, which Rail sends once the exit is settled, so a Follower that restarts gets the whole process again from the runner, as it reads the whole stream file today.

### Signing and git

- `git-remote-rail` and `rail-sign` reach the daemon over `$RAIL_RUNNER_STATE/runner.sock`, which any user in the sandbox may use: one JSON line, then bytes.
- The checkout's config, set by `checkout`, has `gpg.format=ssh`, `gpg.ssh.program=rail-sign` (found on the command's `PATH`), `user.signingkey=key::<public key>`, `commit.gpgsign=true`, and the ticket owner's name and email. Git runs `rail-sign -Y sign -n git -f <key> -U <file>`; the shim sends the file as `sign` and writes `<file>.sig`.
- Rail signs only a commit or tag whose committer is the task's identity, with the owner's key, which never leaves Rail (`ssh-keygen -Y sign -n git`).
- For a `git` channel, Rail runs `git upload-pack` or `git receive-pack` on the task's repo with its hardened environment. Before receive-pack sees a push, Rail reads its commands and refuses any ref but `refs/heads/<branch>`, `refs/rail/wip` and `refs/ci-receipts/*`.

## Rail's side

- `RailWeb.SandboxSocketController` at `/sandbox/socket` checks the request (above) and upgrades it to `Rail.Tools.RunnerSocket`, a `WebSock`, which authenticates the token, registers the connection under the sandbox's id, decodes frames, and on each `hello` runs `checkout` before anything else goes in.
- **The task's repo** is a bare repository Rail keeps beside where the checkout used to be, `<worktree_path>.git`, with Rail's config and the project clone's objects as alternates. It holds the branch as the sandbox last pushed it, `refs/rail/wip`, CI receipts, and `refs/remotes/origin/*` as Rail fetched them. Every git read Rail does about a task (the diff, history, fingerprints, base status, the push to GitHub) runs there, after asking a running sandbox to `sync`. Rail never runs git in a folder a sandbox can write.
- **The Follower** keeps its job and, for a sandboxed process, its input comes from the socket instead of a file: it parses stdout into the run's log as now, and acks `stream_offset` after each commit. The exit comes from `exit`. Liveness is the runner's word, or Docker's while the socket is down.
- **Boot** adopts a sandbox's container by its label, and each running process by starting its Follower, which waits for the runner's `hello`. A container that is gone settles its processes from what was logged, as a process adopted dead does today, and leaves its volume.
- **The `:local` runtime** (dev and the suite) has no isolation and no runner: commands run beside Rail and write their stream files as now. Rail makes the same task repo and gets the checkout from it, and `sync` is Rail running the same pushes in the checkout itself, so everything that reads git reads the task repo either way.

## Project images

- A project may name an image, a Docker reference, for its Linux sandboxes. Without one they use `rail-sandbox`. Images are Docker only: on the Mac a project's setup command builds a cache that `rail-host` copies into each task's home with APFS copy-on-write (RAIL-230). The runner does not care where a cache came from.
- The project's own CI builds it from its default branch, with its toolchain and warmed `deps` and `_build`, and pushes it; hosts pull it. Setup no longer copies `deps` and `_build` from the project's clone, and `RAIL_CLONE_PATH` goes away.
- **Registry: Google Artifact Registry**, in the GCP project that holds Rail's GCS bucket. A project's GitHub Actions push with Workload Identity Federation, so GitHub stores no key; each host pulls with a read-only service account. (GHCR would need a GitHub credential on every host to pull private images.)

## The hostname

**`rail.dishbooks.com/sandbox/socket`**, on the hostname and tunnel Rail already has. Cloudflare Access takes an application scoped to a path, and the most specific path wins, so `/sandbox/socket` gets one of its own that allows only Service Auth (a service token per host) from the hosts' IP allowlist, while the rest of `rail.dishbooks.com` keeps its sign-in for people. Rail checks it too: a request that came through Cloudflare (it carries `Cf-Ray`) must also carry a `Cf-Access-Jwt-Assertion` the team signed for that app's audience tag (`CF_ACCESS_SANDBOX_AUD`), and one without `Cf-Ray` is let in only from a loopback peer, the socket's own address, not a forwarded one. Anything else is refused before the sandbox token is looked at, so a request that reached Rail's port some other way gets nowhere. Sandboxes on Rail's own host use `ws://localhost:4000/sandbox/socket`, and in-cluster hosts the service's private address. On the Mac the runner dials `rail-host`'s local socket, and `rail-host` holds the one connection through the tunnel's path with the host's service token.

## Left to other tickets

- RAIL-228, still: the scratch folder off its mount; the `devtools` channel.
- RAIL-229: sandboxes on a network of their own, so "no other port" holds; hosts as rows; the Mac's `rail-host` and k8s engines.
- Triage, support and curator passes moving into sandboxes like a task's.

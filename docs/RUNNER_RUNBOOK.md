# Rail Runner Operations Runbook

This runbook documents production deployment, node topology, host prerequisites, secret management, database procedures, monitoring, and operational incident runbooks for Rail.

---

## 1. Architecture & Node Topology

Rail processes automated software engineering tasks walking a multi-stage pipeline (`product` → `design` → `architect` → `engineer` → `review` → `qa` → `qa_lead` → `demo` → `ready_to_merge` → `merged`).

### 1.1 Node Roles

In production, cluster deployments run in an asymmetric topology separating **Runner** coordinator nodes from **Web** interactive nodes:

```mermaid
flowchart TD
    subgraph Ingress ["Edge / Load Balancer"]
        LB[Load Balancer / Ingress]
    end

    subgraph WebNodes ["Web Instances (AXIS_NO_DISPATCH=1)"]
        W1[Web Node 1<br/>Phoenix LiveView]
        W2[Web Node 2<br/>Phoenix LiveView]
    end

    subgraph RunnerNode ["Runner Node (AXIS_NO_DISPATCH=0)"]
        R1[Runner Coordinator<br/>Dispatcher + Periodic + Followers]
        SP[Spawner<br/>Task.Supervisor]
        CL1[CLI Runner: Claude]
        CL2[CLI Runner: Agy]
        R1 --> SP
        SP --> CL1
        SP --> CL2
    end

    subgraph Storage ["Shared Infrastructure"]
        DB[(PostgreSQL 17)]
        WT[(Persistent Volume<br/>/var/rail/worktrees)]
        SC[(Persistent Volume<br/>/var/rail/scratch)]
    end

    LB --> W1
    LB --> W2
    LB -. Optional .-> R1

    W1 --> DB
    W2 --> DB
    R1 --> DB

    CL1 --> WT
    CL1 --> SC
    CL2 --> WT
    CL2 --> SC
```

- **Single Runner Node (`AXIS_NO_DISPATCH=0` or unset)**:
  - Executes `Rail.Pipeline.Dispatcher`, which polls eligible queued tasks and starts stage runs.
  - Runs `Rail.Runs.Boot` to adopt or reconcile orphan runs on startup.
  - Spawns CLI processes (Anthropic Claude Code or Google Antigravity) via `Rail.Runs.Spawner`.
  - Runs `Rail.Runs.Follower` to stream NDJSON events from scratch files into the database.
  - Runs `Rail.Periodic` for periodic cron tasks (retries, PR mergeability checks, model refreshing).
- **Web Nodes (`AXIS_NO_DISPATCH=1`)**:
  - Scale horizontally behind an ingress/load balancer.
  - Serve Phoenix LiveView UI and HTTP/API endpoints (`/_health`, OAuth callbacks, Webhooks).
  - Do not pump the pipeline or launch background CLI processes, preventing duplicate coordinators and race conditions.

---

## 2. Host Requirements & Tooling

The runner host executes headless developer CLI tools inside containerized or virtualized environments.

### 2.1 System Software

| Tool | Version Requirement | Purpose |
|---|---|---|
| **OS** | Debian 12 (Bookworm) or Ubuntu 22.04+ LTS | Base Linux distribution |
| **Git** | `>= 2.40.0` | Required for worktree management (`git worktree add`, `git worktree remove`) |
| **GitHub CLI (`gh`)** | `>= 2.40.0` | GitHub authentication and PR lifecycle operations |
| **OpenSSL / CA Certs** | Modern TLS 1.3 | Secure HTTPS calls to Linear and GitHub APIs |
| **libstdc++6** | Standard | C++ runtime required by Erlang NIFs and CLI tools |
| **jq** | Modern | JSON filtering and shell scripting |
| **Locales** | `en_US.UTF-8` | Ensures UTF-8 encoding across CLI stdout streams |

### 2.2 CLI Runner Accounts

Stage agents require authenticated command-line interfaces installed and configured under the `rail` user:

- **Anthropic Claude Code CLI (`claude`)**:
  - Authentication stored under `/home/rail/.claude` or via `ANTHROPIC_API_KEY`.
  - Ensure binary is executable at `/usr/local/bin/claude` or on `$PATH`.
- **Google Antigravity CLI (`agy`)**:
  - Authentication stored under `/home/rail/.gemini` or via `GEMINI_API_KEY`.
  - Ensure binary is executable at `/usr/local/bin/agy` or on `$PATH`.

Verify CLI availability with:
```bash
su - rail -c "git --version"
su - rail -c "gh --version"
su - rail -c "claude --version"
su - rail -c "agy --version"
```

---

## 3. Persistent Storage & Directories

Rail relies on two persistent directory trees mounted on the runner host:

```
/var/rail/
├── worktrees/   # Persistent git worktrees checked out per task
│   └── <project_slug>/
│       └── <worktree_name>/
└── scratch/     # Task artifacts, stream NDJSON files, and demo recordings
    └── <task_id>/
        ├── streams/
        ├── qa/
        └── demo/
```

### 3.1 Permissions

Directories must be owned by user `rail` (UID `1000`) and group `rail` (GID `1000`):
```bash
sudo mkdir -p /var/rail/worktrees /var/rail/scratch
sudo chown -R 1000:1000 /var/rail
sudo chmod -R 0750 /var/rail
```

### 3.2 Cleanup & Pruning Policies

1. **Worktrees**:
   - Maintained during task execution.
   - Cleaned up automatically upon task merge (`Rail.Pipeline.Actions.MergePr`) or manual cancellation.
   - Periodic runbook removes abandoned worktrees older than 14 days.
2. **Scratch**:
   - Stream files (`.ndjson`) are parsed and ingested into `run_events` by `Follower`.
   - Pruned by `Rail.Runs.PruneRunEvents` according to retention configuration.

---

## 4. Secrets & Credentials Configuration

Sensitive configuration is loaded at runtime via environment variables (`config/runtime.exs`).

### 4.1 Production Environment Variables

| Variable | Description | Example / Format |
|---|---|---|
| `DATABASE_URL` | PostgreSQL connection URL | `ecto://postgres:password@postgres-host:5432/rail_prod` |
| `SECRET_KEY_BASE` | Phoenix session & cookie signing secret | 64-byte random string generated via `mix phx.gen.secret` |
| `CLOAK_KEY_V1` | Cloak AES-256-GCM master encryption key | 32-byte Base64-encoded binary key |
| `PHX_HOST` | Fully qualified public host domain | `rail.example.com` |
| `PORT` | Listening HTTP port | `4000` |
| `PHX_SERVER` | Enable Phoenix HTTP endpoint | `true` |
| `POOL_SIZE` | Ecto database connection pool size | `10` (default) to `30` |
| `AXIS_NO_DISPATCH` | Disable runner coordination (web nodes) | `1` (web nodes), `0` (runner node) |
| `GITHUB_APP_ID` | GitHub App numerical ID | `123456` |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App PEM private key | `-----BEGIN RSA PRIVATE KEY-----...` |
| `LINEAR_CLIENT_ID` | Linear OAuth application client ID | `lin_client_...` |
| `LINEAR_CLIENT_SECRET` | Linear OAuth client secret | `lin_secret_...` |
| `LINEAR_REDIRECT_URI` | Linear OAuth redirect callback URL | `https://rail.example.com/auth/linear/callback` |

### 4.2 Key Generation

#### `CLOAK_KEY_V1` (AES-256-GCM)
Generate a fresh 256-bit cryptographic key:
```bash
openssl rand -base64 32
```

#### `SECRET_KEY_BASE`
Generate a Phoenix secret key:
```bash
mix phx.gen.secret
```

### 4.3 Cloak Key Rotation

Cloak supports zero-downtime key rotation through tagged ciphers:
1. Define the new key as `CLOAK_KEY_V2`.
2. Add `AES.GCM.V2` with `tag: "AES.GCM.V2"` as the primary cipher in `Rail.Vault`.
3. Keep `AES.GCM.V1` as a secondary cipher in `Rail.Vault` so existing records decrypt.
4. Run `mix cloak.migrate.ecto -r Rail.Repo -s Rail.Users.Schemas.User -c [:github_token, :linear_access_token]` to re-encrypt data under V2.
5. Deprecate and remove `CLOAK_KEY_V1`.

---

## 5. Database Operations

In production releases where `mix` is unavailable, database operations are executed through `Rail.Release`.

### 5.1 Running Pending Migrations
```bash
/app/bin/rail eval "Rail.Release.migrate()"
```

### 5.2 Rolling Back Migrations
Roll back migrations for a repository to a target migration version:
```bash
/app/bin/rail eval "Rail.Release.rollback(Rail.Repo, 20260909173244)"
```

### 5.3 Seeding Default Data
Run idempotent seeds to initialize default admin account, project, and pipeline stage roles:
```bash
/app/bin/rail eval "Rail.Release.seed()"
```
This initializes:
- Default Admin User: `admin@rail.local` (Admin privileges)
- Default Project: `Rail` (`Rail-AI-dev/rail`, default branch `main`)
- 8 Pipeline Stage Roles: `product`, `architect`, `design`, `engineer`, `review`, `qa`, `qa_lead`, `demo`

---

## 6. Deployment Guides

### 6.1 Docker Compose Deployment

A turnkey setup is provided via `docker-compose.yml`:
```bash
# 1. Start database and wait for health
docker compose up -d db

# 2. Run migrations
docker compose run --rm rail eval "Rail.Release.migrate()"

# 3. Seed default admin & roles
docker compose run --rm rail eval "Rail.Release.seed()"

# 4. Start all services
docker compose up -d
```

### 6.2 Kubernetes Helm Deployment

Deploying with Helm:
```bash
# 1. Lint the chart
helm lint deploy/helm/rail

# 2. Dry-run template generation
helm template rail deploy/helm/rail -f my-values.yaml

# 3. Install or upgrade chart
helm upgrade --install rail deploy/helm/rail \
  --namespace rail \
  --create-namespace \
  --values my-values.yaml
```

---

## 7. Monitoring & Healthchecks

### 7.1 Health Probes
- **Path**: `GET /_health`
- **Port**: `4000`
- **Expected Status**: `200 OK`
- **Response Body**: `ok`
- **Use**: Kubernetes `livenessProbe` and `readinessProbe`.

### 7.2 Metrics & Telemetry
- Phoenix LiveDashboard is available at `/dashboard` for authenticated admin users.
- Telemetry metrics capture:
  - VM Memory and run queue lengths (`:telemetry_poller`)
  - Database query counts and durations (`[:rail, :repo, :query]`)
  - Bandit HTTP connection and request durations (`[:bandit, :request, :stop]`)
  - Pipeline Dispatcher pump durations and dispatch rates

---

## 8. Incident Runbooks & Troubleshooting

### 8.1 Orphan Process Recovery

**Symptom**: A CLI process continues running after its run was stopped, or after a node restart.

**Diagnosis**:
1. Check running processes owned by `rail`:
   ```bash
   ps aux | grep -E "claude|agy"
   ```
2. Cross-reference process IDs with active runs in the database:
   ```bash
   /app/bin/rail eval "Rail.Runs.list_active_runs() |> IO.inspect()"
   ```

**Remediation**:
1. Rail automatically adopts or marks abandoned runs as stopped on restart via `Rail.Runs.Boot.adopt_live_runs/1`.
2. To manually terminate orphan CLI processes:
   ```bash
   pkill -u rail -f "claude"
   pkill -u rail -f "agy"
   ```

### 8.2 Scratch Disk Exhaustion

**Symptom**: Runner node alerts with `No space left on device` under `/var/rail/scratch`.

**Remediation**:
1. Identify large files:
   ```bash
   du -sh /var/rail/scratch/* | sort -hr | head -n 20
   ```
2. Run automated log prune:
   ```bash
   /app/bin/rail eval "Rail.Runs.prune_old_events(7)"
   ```
3. Remove abandoned scratch directories for merged or cancelled tasks older than 30 days:
   ```bash
   find /var/rail/scratch -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
   ```

### 8.3 Database Connection Pool Starvation

**Symptom**: `DBConnection.ConnectionError: tcp connect: connection refused` or timeout waiting for checked-out connection.

**Remediation**:
1. Inspect current pool size configuration (`POOL_SIZE` env var, defaults to 10).
2. Increase pool size in deployment values (e.g. `POOL_SIZE: "20"` or `"30"`).
3. Ensure PostgreSQL server `max_connections` is comfortably above:
   `sum(POOL_SIZE for all nodes) + 20 reserved for admin/migration`.

### 8.4 GitHub Rate Limiting

**Symptom**: HTTP 403 `API rate limit exceeded` from GitHub client.

**Remediation**:
1. Check GitHub App token expiration and rate limit status:
   ```bash
   gh api /rate_limit
   ```
2. Verify that GitHub App authentication is used rather than personal access tokens (GitHub Apps have 5,000 req/hr per installation).
3. If necessary, wait for the rate limit reset window (`x-ratelimit-reset` Unix timestamp).

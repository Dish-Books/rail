alias Rail.Projects.Schemas.Project
alias Rail.Roles.Schemas.Role
alias Rail.Tools.Schemas.Backend

# `System.unique_integer/1` starts over every boot, so a temp path built from it can be one an
# earlier run, or another suite on the same machine, left behind. Each run gets its own; kept short for socket paths.
run_tmp_dir = Path.join(System.tmp_dir!(), "rt#{System.pid()}")
# The shared Chrome is detached, like it is beside Rail in dev, and its profile is under its run's
# directory - which is how the one a run started is told apart from anybody else's. The slash keeps
# rt123's from matching rt1234's.
stop_chrome = fn dir -> System.cmd("pkill", ["-f", "--", "--user-data-dir=#{dir}/"], stderr_to_stdout: true, env: []) end

# A run cut short never reaches `after_suite`, so its Chrome is still up. One whose run is gone is
# stopped here; another suite still running keeps its own.
for stale <- Path.wildcard(Path.join(System.tmp_dir!(), "rt*")),
    {os_pid, ""} <- [Integer.parse(String.trim_leading(Path.basename(stale), "rt"))],
    match?({_out, 1}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true, env: [])) do
  stop_chrome.(stale)
  File.rm_rf(stale)
end

File.rm_rf!(run_tmp_dir)
File.mkdir_p!(run_tmp_dir)
System.put_env("TMPDIR", run_tmp_dir)
# Tasks' clones are named for their branch, so another suite on the same machine would make the same ones.
Application.put_env(:rail, :tasks_root, Path.join(run_tmp_dir, "tasks"))
# A test writes in a checkout and reads it back at once, so each read syncs; the one test of the window stubs it.
Application.put_env(:rail, :checkout_sync_ms, 0)

ExUnit.after_suite(fn _result ->
  stop_chrome.(run_tmp_dir)
  File.rm_rf(run_tmp_dir)
end)

Mimic.copy(Date)
Mimic.copy(DateTime)
Mimic.copy(File)
Mimic.copy(Goth)
Mimic.copy(Goth.Config)
Mimic.copy(Port)
Mimic.copy(Rail)
Mimic.copy(Rail.Git)
Mimic.copy(Rail.Users)
Mimic.copy(Rail.Issues)
Mimic.copy(Rail.Learnings)
Mimic.copy(Rail.Mcp)
Mimic.copy(Rail.Pipeline)
Mimic.copy(Rail.Pipeline.Utils.PrepareTurn)
Mimic.copy(Rail.Pipeline.Utils.ClaimWorktreeSlot)
Mimic.copy(Rail.Pipeline.Utils.DropWorktreeDatabases)
Mimic.copy(Rail.Tools)
Mimic.copy(Rail.Roles)
Mimic.copy(Rail.Tools.Browser)
Mimic.copy(Rail.Tools.Claude)
Mimic.copy(Rail.Triage)
Mimic.copy(Rail.Tools.BrowserSession)
Mimic.copy(Rail.Tools.Clients.Speech)
Mimic.copy(RailWeb.Endpoint)
Mimic.copy(RailWeb.Utils.MonotonicMs)
Mimic.copy(Rail.Tools.FollowerSupervisor)
Mimic.copy(Rail.Issues.Tracker)

# Ensure that all Req calls are mocked by default
Req.default_options(adapter: fn req -> raise "Unmocked call to #{req.url}" end)

# CI runners are slow enough that the default 100ms flakes; render_async reads it too.
# A test tagged :docker runs a real container; `mix test --include docker` runs it where Docker is.
ExUnit.start(capture_log: true, assert_receive_timeout: 1_000, exclude: [:docker])

# One project, with a role for every stage, that every test can hang its
# rows off; see `Rail.DataCase`. Tests only read the roles, so none races another inserting one.
# Committed before the sandbox takes over, with fixed ids so a rerun rewrites the same rows.
upsert = [on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: :id]

project =
  Rail.Repo.insert!(
    %Project{
      id: "prj_test_seed",
      name: "Test Project",
      github_repo: "example/test-seed",
      github_installation_id: 1,
      default_branch: "main",
      key: "TST",
      # Under the run's own directory: tasks' worktrees are named for their issue, so a fixed path
      # is one another suite on the same machine builds and removes too.
      clone_path: Path.join(run_tmp_dir, "repos/test-seed")
    },
    upsert
  )

# A second project, for tests that need one beside the first.
github_project =
  Rail.Repo.insert!(
    %Project{
      id: "prj_test_seed_github",
      name: "Test GitHub Project",
      github_repo: "example/test-gh",
      github_installation_id: 1,
      default_branch: "main",
      key: "tgh",
      clone_path: Path.join(run_tmp_dir, "repos/test-gh")
    },
    upsert
  )

# Signed in and offering the seeded roles' model, so their runs have an account to be placed on.
Rail.Repo.insert!(
  %Backend{
    id: "bkd_test_seed",
    name: :claude,
    executable_path: "/usr/bin/true",
    status: :ready,
    models: [%Backend.Model{id: "claude-opus-5-5", display_name: "Opus 5.5"}]
  },
  upsert
)

for {seeded, prefix} <- [{project, "rol_test_seed"}, {github_project, "rol_test_seed_gh"}],
    stage <- Role.canonical_stages() do
  Rail.Repo.insert!(
    %Role{
      id: "#{prefix}_#{stage}",
      project_id: seeded.id,
      cli: :claude,
      stage: stage,
      name: "#{stage} role",
      model: "claude-opus-5-5",
      system_prompt: "You are the #{stage} agent."
    },
    upsert
  )
end

# The custom stages tests enter on the shared project, made once and committed: each test's own first entry would
# hold the row's insert open until it ended, and every other test entering that stage would wait on it.
for name <- ["License check", "Missing strings", "Schema review"] do
  {:ok, _role} = Rail.Roles.get_custom_stage_role(project.id, name)
end

:persistent_term.put({RailTest, :project}, project)
:persistent_term.put({RailTest, :github_project}, github_project)

# A data migration run against a database already seeded queues jobs for the seeded projects, and a committed job
# shows in every test's `all_enqueued`.
Rail.Repo.delete_all("oban_jobs")

Ecto.Adapters.SQL.Sandbox.mode(Rail.Repo, :manual)

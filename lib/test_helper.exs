alias Rail.Projects.Schemas.LinearWorkspace
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
Mimic.copy(Rail.Mcp)
Mimic.copy(Rail.Pipeline)
Mimic.copy(Rail.Pipeline.Utils.PrepareWorktree)
Mimic.copy(Rail.Tools)
Mimic.copy(Rail.Roles)
Mimic.copy(Rail.Tools.Browser)
Mimic.copy(Rail.Tools.BrowserSession)
Mimic.copy(Rail.Tools.FollowerSupervisor)

# Ensure that all Req calls are mocked by default
Req.default_options(adapter: fn req -> raise "Unmocked call to #{req.url}" end)

# CI runners are slow enough that the default 100ms flakes; render_async reads it too.
ExUnit.start(capture_log: true, assert_receive_timeout: 1_000)

# One project on one workspace, with a role for every stage, that every test can hang its
# rows off; see `Rail.DataCase`. Tests only read the roles, so none races another inserting one.
# Committed before the sandbox takes over, with fixed ids so a rerun rewrites the same rows.
upsert = [on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: :id]

workspace =
  Rail.Repo.insert!(
    %LinearWorkspace{
      id: "lw_test_seed",
      name: "Test Workspace",
      external_id: "lin_org_test_seed",
      token: "lin_api_test_seed",
      webhook_secret: "whsec_test_seed"
    },
    upsert
  )

project =
  Rail.Repo.insert!(
    %Project{
      id: "prj_test_seed",
      name: "Test Project",
      github_repo: "example/test-seed",
      github_installation_id: 1,
      default_branch: "main",
      linear_team_key: "TST",
      linear_team_id: "lin_team_id",
      linear_state_ids: %{
        "triage" => "st_triage",
        "backlog" => "st_backlog",
        "todo" => "st_todo",
        "in_progress" => "st_in_progress",
        "done" => "st_done",
        "canceled" => "st_canceled"
      },
      linear_workspace_id: "lw_test_seed",
      clone_path: "/tmp/repos/test-seed"
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

Enum.each(Role.canonical_stages(), fn stage ->
  Rail.Repo.insert!(
    %Role{
      id: "rol_test_seed_#{stage}",
      project_id: project.id,
      cli: :claude,
      stage: stage,
      name: "#{stage} role",
      model: "claude-opus-5-5",
      system_prompt: "You are the #{stage} agent."
    },
    upsert
  )
end)

:persistent_term.put({RailTest, :project}, %{project | linear_workspace: workspace})

Ecto.Adapters.SQL.Sandbox.mode(Rail.Repo, :manual)

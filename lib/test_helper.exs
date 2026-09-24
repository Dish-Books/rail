alias Rail.Projects.Schemas.LinearWorkspace
alias Rail.Projects.Schemas.Project

Mimic.copy(Date)
Mimic.copy(DateTime)
Mimic.copy(File)
Mimic.copy(Rail.Git)
Mimic.copy(Rail.Users)
Mimic.copy(Rail.Issues)
Mimic.copy(Rail.Mcp)
Mimic.copy(Rail.Tools)
Mimic.copy(Rail.Roles)
Mimic.copy(Rail.Tools.Browser)
Mimic.copy(Rail.Tools.BrowserSession)
Mimic.copy(Rail.Tools.FollowerSupervisor)

# Ensure that all Req calls are mocked by default
Req.default_options(adapter: fn req -> raise "Unmocked call to #{req.url}" end)

# CI runners are slow enough that the default 100ms flakes; render_async reads it too.
ExUnit.start(capture_log: true, assert_receive_timeout: 1_000)

# One project on one workspace that every test can hang its rows off; see `Rail.DataCase`.
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
        "in_progress" => "st_in_progress",
        "done" => "st_done",
        "canceled" => "st_canceled"
      },
      linear_workspace_id: "lw_test_seed",
      clone_path: "/tmp/repos/test-seed"
    },
    upsert
  )

:persistent_term.put({RailTest, :project}, %{project | linear_workspace: workspace})

Ecto.Adapters.SQL.Sandbox.mode(Rail.Repo, :manual)

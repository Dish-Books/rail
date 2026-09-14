defmodule Rail.Pipeline.Actions.ListRunsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "List Runs Project",
        github_repo: "org/list-runs",
        github_installation_id: 49_001,
        linear_workspace: %{
          name: "List Runs Workspace",
          external_id: "lin_ws_list_runs",
          token: "lin_api_token_list_runs",
          webhook_secret: "whsec_list_runs"
        },
        linear_team_key: "LST",
        default_branch: "main",
        clone_path: "/tmp/repos/list-runs",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_list_runs_1", "identifier" => "LST-1", "title" => "List Runs Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Runs Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{project: project, task: task, run: run}
  end

  test "leaves out runs on cleaned-up tasks unless asked", %{project: project, task: task, run: %Run{id: run_id}} do
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    assert [] = Pipeline.list_runs(project_id: project.id)
    assert [%Run{id: ^run_id}] = Pipeline.list_runs(project_id: project.id, include_cleaned_up: true)
  end

  test "lists every run, preloaded as asked", %{run: %Run{id: run_id}} do
    assert [%Run{id: ^run_id, task: %Task{}}] = Pipeline.list_runs(preload: [:task])
  end

  test "lists only the runs of one project", %{project: project, run: %Run{id: run_id}} do
    assert [%Run{id: ^run_id}] = Pipeline.list_runs(project_id: project.id)
    assert [] = Pipeline.list_runs(project_id: "prj_other")
  end
end

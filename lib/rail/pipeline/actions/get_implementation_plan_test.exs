defmodule Rail.Pipeline.Actions.GetImplementationPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Plan Project",
        github_repo: "org/get-plan",
        github_installation_id: 47_007,
        linear_workspace: %{
          name: "Get Plan Workspace",
          external_id: "lin_ws_get_plan",
          token: "lin_api_token_get_plan",
          webhook_secret: "whsec_get_plan"
        },
        linear_team_key: "GTP",
        default_branch: "main",
        clone_path: "/tmp/repos/get-plan",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_get_plan_1", "identifier" => "GTP-1", "title" => "Get Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Get Plan"})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "returns the approved plan", %{task: task} do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "## Implementation plan",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %ImplementationPlan{content: "## Implementation plan"}} =
             Pipeline.get_implementation_plan(task)
  end

  test "a task whose plan nobody approved has none", %{task: task} do
    assert {:error, :not_found} = Pipeline.get_implementation_plan(task)
  end
end

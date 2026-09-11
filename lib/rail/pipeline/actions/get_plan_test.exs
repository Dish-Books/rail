defmodule Rail.Pipeline.Actions.GetPlanTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CaptureScratch

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Get Plan Workspace",
        external_id: "lin_ws_get_plan",
        token: "lin_api_token_get_plan",
        webhook_secret: "whsec_get_plan"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Plan Project",
        github_repo: "org/get-plan",
        github_installation_id: 6501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_get_plan",
        linear_team_key: "GPL",
        default_branch: "main",
        clone_path: "/tmp/repos/get-plan",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_get_plan_1",
      "identifier" => "GPL-1",
      "title" => "Get Plan Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Get Plan Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, task: task}
  end

  test "returns latest plan for system scope and user scope", %{task: task} do
    sys_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    expect(File, :exists?, 2, fn path -> String.ends_with?(path, "plan.md") end)
    expect(File, :read!, fn _path -> "# Old Plan" end)
    {:ok, _task} = capture_scratch(:architect, %{task | scratch_path: "/tmp/rail_scratch/get_plan_1"})

    expect(File, :exists?, 2, fn path -> String.ends_with?(path, "plan.md") end)
    expect(File, :read!, fn _path -> "# New Plan" end)
    {:ok, _task} = capture_scratch(:architect, %{task | scratch_path: "/tmp/rail_scratch/get_plan_2"})

    assert {:ok, %Plan{id: expected_plan_id, content: "# New Plan"}} = Pipeline.get_plan(sys_scope, task.id)

    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(user_scope, task)
    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(task.id)
    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(task)
  end

  test "returns not found error when plan does not exist", %{task: task} do
    sys_scope = Scope.for_system()

    assert {:error, :not_found} = Pipeline.get_plan(sys_scope, task.id)
    assert {:error, :not_found} = Pipeline.get_plan(sys_scope, "tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.get_plan(12_345)
  end

  test "returns not authorized error for invalid scope", %{task: task} do
    assert {:error, :not_authorized} = Pipeline.get_plan(nil, task.id)
    assert {:error, :not_authorized} = Pipeline.get_plan(%Scope{user: nil, system: false}, task.id)
  end
end

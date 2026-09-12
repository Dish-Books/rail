defmodule Rail.Pipeline.Schemas.ImplementationPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Plan Schema Workspace",
        external_id: "lin_ws_plan_schema",
        token: "lin_api_token_plan_schema",
        webhook_secret: "whsec_plan_schema"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Plan Schema Project 7601",
        github_repo: "org/plan-schema-7601",
        github_installation_id: 7601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_plan_schema_7601",
        linear_team_key: "P7601",
        default_branch: "main",
        clone_path: "/tmp/repos/plan-schema-7601",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_plan_schema_1",
      "identifier" => "PSC-1",
      "title" => "Plan Schema Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Plan Schema Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "changeset validates required fields" do
    assert %{
             task_id: ["can't be blank"],
             content: ["can't be blank"],
             captured_at: ["can't be blank"]
           } = errors_on(ImplementationPlan.changeset(%ImplementationPlan{}, %{}))
  end

  test "changeset accepts valid attributes", %{task: task} do
    now = DateTime.utc_now()

    attrs = %{
      content: "# Plan for Task\n\n1. Do X\n2. Do Y",
      captured_at: now
    }

    changeset = ImplementationPlan.changeset(%ImplementationPlan{}, attrs, task.id)

    assert changeset.valid?
    assert get_field(changeset, :task_id) == task.id
    assert get_field(changeset, :content) == "# Plan for Task\n\n1. Do X\n2. Do Y"
    assert get_field(changeset, :captured_at) == now
  end

  test "validates foreign key on task_id" do
    now = DateTime.utc_now()

    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %ImplementationPlan{}
             |> ImplementationPlan.changeset(
               %{content: "Content", captured_at: now},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task", %{task: task} do
    %Task{id: task_id} = task = task

    plan =
      Repo.insert!(
        ImplementationPlan.changeset(
          %ImplementationPlan{},
          %{
            content: "Content for preloaded task",
            captured_at: DateTime.utc_now()
          },
          task.id
        )
      )

    preloaded = Repo.preload(plan, :task)

    assert %ImplementationPlan{task: %Task{id: ^task_id}} = preloaded
  end
end

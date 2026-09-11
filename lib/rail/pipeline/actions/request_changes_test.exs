defmodule Rail.Pipeline.Actions.RequestChangesTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Request Changes Workspace",
        external_id: "lin_ws_request_changes",
        token: "lin_api_token_request_changes",
        webhook_secret: "whsec_request_changes"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Request Changes Project 8501",
        github_repo: "org/request-changes-8501",
        github_installation_id: 8501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_request_changes_8501",
        linear_team_key: "P8501",
        clone_path: "/tmp/repos/request-changes-8501",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_request_changes_1",
      "identifier" => "RQC-1",
      "title" => "Request Changes Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Request Changes Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.request_changes("tsk_000000000000000000000000", "Fix this")
  end

  test "returns not_authorized when scope lacks permission", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.request_changes(unauth_scope, task.id, "Fix this")
  end

  test "returns empty_comment when comment is empty or whitespace", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:error, :empty_comment} = Pipeline.request_changes(task, "")
    assert {:error, :empty_comment} = Pipeline.request_changes(task, "   ")
    assert {:error, :empty_comment} = Pipeline.request_changes(task, nil)
  end

  test "returns role_not_found when target stage role is not configured", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:architect])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:error, :role_not_found} =
             Pipeline.request_changes(task, "Please rethink architecture")
  end

  test "queues target stage and appends comment to role_run pending_answer", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, role_arch} =
      Roles.update_role(system_scope(), roles[:architect], %{
        name: "Architect"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval,
        error: "Some error"
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_arch.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        auto_retries: 2,
        pending_answer: "Initial notes"
      })

    assert {:ok, %Task{id: ^task_id, stage: :architect, stage_state: :queued, error: nil}} =
             Pipeline.request_changes(task, "Clarify database model")

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :changes_requested}}

    arch_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_arch.id)
    assert arch_run.pending_answer == "Initial notes\n\nClarify database model"
    assert arch_run.auto_retries == 0
  end

  test "creates role_run if one did not exist yet", %{task: task, roles: roles} do
    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :review, stage_state: :queued}} =
             Pipeline.request_changes(task, "Add test coverage")

    rev_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_rev.id)
    assert rev_run.pending_answer == "Add test coverage"
    assert rev_run.auto_retries == 0
  end

  test "delegates to send_back_to_engineer when target stage is ready_to_merge", %{task: task, roles: roles} do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{id: ^task_id, stage: :engineer, stage_state: :queued}} =
             Pipeline.request_changes(task, "Need bugfix before merge", stage: :ready_to_merge)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "What the human asked for:\n\nNeed bugfix before merge"
  end

  test "routes to engineer while preserving task.stage when task is rebasing", %{task: task, roles: roles} do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running,
        is_rebasing: true
      })

    assert {:ok, %Task{stage: :qa, stage_state: :queued}} =
             Pipeline.request_changes(task, "Resolve merge conflict cleanly")

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Resolve merge conflict cleanly"
  end

  test "authorizes scope with user and handles invalid task argument", %{task: task, roles: roles} do
    {:ok, _role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval
      })

    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    assert {:ok, %Task{stage: :engineer}} = Pipeline.request_changes(user_scope, task.id, "Need rework")
    assert {:ok, %Task{stage: :engineer}} = Pipeline.request_changes(user_scope, task.id, "Need rework", stage: :engineer)
    assert {:error, :not_found} = Pipeline.request_changes(user_scope, :invalid_task, "Need rework")
  end

  test "formats pending_answer with design_revise_brief when direction is picked at design stage", %{
    task: task,
    roles: roles
  } do
    {:ok, role_des} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_scratch_8551 = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir_8551 = Path.join(design_scratch_8551, "design")
    File.mkdir_p!(design_dir_8551)
    on_exit(fn -> File.rm_rf(design_scratch_8551) end)

    File.write!(Path.join(design_dir_8551, "dir-1.png"), "fake png content")

    File.write!(
      Path.join(design_dir_8551, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-8551",
        "version" => 1,
        "pickedKey" => "dir-1",
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })
    )

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, design_scratch_8551, url_probe: fn _url -> true end)

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_des.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.request_changes(task, "Please make headers bolder")

    des_run = Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^role_des.id)
    assert des_run.pending_answer =~ "The human requested revisions to the picked design:"
    assert des_run.pending_answer =~ "Please make headers bolder"
    assert des_run.pending_answer =~ "rewrite $RAIL_SCRATCH/design/manifest.json with an incremented `version`"

    events = Repo.all(from e in RunEvent, where: e.role_run_id == ^des_run.id, order_by: [asc: e.seq])
    assert Enum.any?(events, fn e -> e.line == "[human] Please make headers bolder" end)
  end

  test "does not wrap comment in design_revise_brief before a pick at design stage", %{task: task, roles: roles} do
    {:ok, role_des} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_scratch_8552 = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir_8552 = Path.join(design_scratch_8552, "design")
    File.mkdir_p!(design_dir_8552)
    on_exit(fn -> File.rm_rf(design_scratch_8552) end)

    File.write!(Path.join(design_dir_8552, "dir-1.png"), "fake png content")

    File.write!(
      Path.join(design_dir_8552, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-8552",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })
    )

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, design_scratch_8552, url_probe: fn _url -> true end)

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_des.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.request_changes(task, "None of these work, try a dark theme")

    des_run = Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^role_des.id)
    assert des_run.pending_answer == "None of these work, try a dark theme"
    refute des_run.pending_answer =~ "rewrite $RAIL_SCRATCH/design/manifest.json"

    events = Repo.all(from e in RunEvent, where: e.role_run_id == ^des_run.id, order_by: [asc: e.seq])
    assert Enum.any?(events, fn e -> e.line == "[human] None of these work, try a dark theme" end)
  end
end

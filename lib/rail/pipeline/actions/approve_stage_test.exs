defmodule Rail.Pipeline.Actions.ApproveStageTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias RailTest.Mocks.Linear
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Approve Stage Workspace",
        external_id: "lin_ws_approve_stage",
        token: "lin_api_token_approve_stage",
        webhook_secret: "whsec_approve_stage"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Approve Stage Project 10501",
        github_repo: "org/approve-stage-10501",
        github_installation_id: 10_501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_approve_stage_10501",
        linear_team_key: "P10501",
        clone_path: "/tmp/repos/approve-stage-10501",
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
      "id" => "lin_approve_stage_1",
      "identifier" => "APS-1",
      "title" => "Approve Stage Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Approve Stage Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_approve_stage_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.approve_stage("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage_state: :awaiting_approval
      })

    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.approve_stage(unauth_scope, task.id, [])
  end

  test "returns invalid_stage_state when task is not awaiting_approval", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage_state: :queued
      })

    assert {:error, {:invalid_stage_state, :queued}} = Pipeline.approve_stage(task)
  end

  test "returns error when task is already at ready_to_merge", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval
      })

    assert {:error, :cannot_approve_ready_to_merge} = Pipeline.approve_stage(task)
  end

  test "advances product stage to design when design role exists", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    _design_role = roles[:design]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval,
        error: "prior error"
      })

    assert {:ok, %Task{stage: :design, stage_state: :queued, error: nil}} =
             Pipeline.approve_stage(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_approved}}
  end

  test "advances product stage to architect when skip_design is true", %{task: task, roles: roles} do
    _design_role = roles[:design]
    _arch_role = roles[:architect]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect, stage_state: :queued}} =
             Pipeline.approve_stage(task, skip_design: true)
  end

  test "approving product when no designer role is configured parks visibly with error", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:design])

    _arch_role = roles[:architect]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :design, stage_state: :failed, error: err}} =
             Pipeline.approve_stage(task)

    assert err =~ "No role \"design\" is configured"
  end

  test "approving product with skip_design moves task directly from product to architect", %{task: task, roles: roles} do
    _arch_role = roles[:architect]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect, stage_state: :queued}} =
             Pipeline.approve_stage(task, skip_design: true)
  end

  test "advances intermediate stages in standard pipeline order", %{
    project: project,
    issue: issue,
    task: task,
    roles: roles
  } do
    _arch = roles[:architect]
    _eng = roles[:engineer]
    _rev = roles[:review]
    _qa = roles[:qa]
    _lead = roles[:qa_lead]

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Approve Stage Workspace 10511",
        external_id: "lin_ws_approve_stage_10511",
        token: "lin_api_token_approve_stage_10511",
        webhook_secret: "whsec_approve_stage_10511"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_approve_stage_10506",
      "identifier" => "ENG-101",
      "title" => "Approve Stage Issue 10506"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Approve Stage Issue 10506")

    {:ok, t_design} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_manifest_11001 =
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-11001",
        "version" => 1,
        "pickedKey" => "dir-1",
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })

    expect(File, :exists?, 2, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, design_manifest_11001} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), t_design, "/tmp/rail_scratch/design_11001", url_probe: fn _url -> true end)

    LinearMock.mock_create_comment_success(%{"id" => "com_101", "body" => "Design comment"})
    assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(t_design)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_approve_stage_10502",
      "identifier" => "TSK-10502",
      "title" => "Task 10502"
    })

    {:ok, issue_10502} = Issues.capture_issue(system_scope(), project, "Task 10502")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_approve_stage_10502"})

    {:ok, t_arch} = Pipeline.bring_local(system_scope(), issue_10502)

    {:ok, t_arch} =
      Pipeline.update_task(system_scope(), t_arch.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer}} = Pipeline.approve_stage(t_arch)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_approve_stage_10503",
      "identifier" => "TSK-10503",
      "title" => "Task 10503"
    })

    {:ok, issue_10503} = Issues.capture_issue(system_scope(), project, "Task 10503")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_approve_stage_10503"})

    {:ok, t_eng} = Pipeline.bring_local(system_scope(), issue_10503)

    {:ok, t_eng} =
      Pipeline.update_task(system_scope(), t_eng.id, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :review}} = Pipeline.approve_stage(t_eng)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_approve_stage_10504",
      "identifier" => "TSK-10504",
      "title" => "Task 10504"
    })

    {:ok, issue_10504} = Issues.capture_issue(system_scope(), project, "Task 10504")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_approve_stage_10504"})

    {:ok, t_rev} = Pipeline.bring_local(system_scope(), issue_10504)

    {:ok, t_rev} =
      Pipeline.update_task(system_scope(), t_rev.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :qa}} = Pipeline.approve_stage(t_rev)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_approve_stage_10505",
      "identifier" => "TSK-10505",
      "title" => "Task 10505"
    })

    {:ok, issue_10505} = Issues.capture_issue(system_scope(), project, "Task 10505")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_approve_stage_10505"})

    {:ok, t_qa} = Pipeline.bring_local(system_scope(), issue_10505)

    {:ok, t_qa} =
      Pipeline.update_task(system_scope(), t_qa.id, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :qa_lead}} = Pipeline.approve_stage(t_qa)
  end

  test "advances qa_lead to demo if demo role exists", %{task: task, roles: roles} do
    _demo = roles[:demo]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :demo, stage_state: :queued}} =
             Pipeline.approve_stage(task)
  end

  test "advances qa_lead to ready_to_merge awaiting_approval if demo role absent", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:demo])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.approve_stage(task)
  end

  test "advances demo stage to ready_to_merge awaiting_approval", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.approve_stage(task)
  end

  test "sets stage_state to failed when next stage has no configured role", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:engineer])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :failed, error: err}} =
             Pipeline.approve_stage(task)

    assert err =~ "No role \"engineer\" is configured"
  end

  test "supports scope-based invocation with task struct or id", %{task: task, roles: roles} do
    _eng = roles[:engineer]
    scope = Scope.for_system()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer}} = Pipeline.approve_stage(scope, task, [])
  end

  test "authorizes scope with user and supports 2-argument invocation", %{task: task, roles: roles} do
    _eng = roles[:engineer]
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer}} = Pipeline.approve_stage(user_scope, task.id)
    assert {:error, :not_found} = Pipeline.approve_stage(user_scope, :invalid_task)
  end

  describe "approve_stage design validation and publishing edge cases" do
    test "fails when task has no linked issue", %{issue: issue, task: task} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: nil,
          stage: :design,
          stage_state: :awaiting_approval
        })

      assert {:error, :no_issue} = Pipeline.approve_stage(task)
      task = Repo.get(Task, task.id)
      assert task.error =~ "has no GitHub issue"
    end

    test "fails when linked issue does not exist in database", %{issue: issue, task: task} do
      {:ok, %Task{} = task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :awaiting_approval
        })

      task = %{task | issue_id: "iss_000000000000000000000000"}

      assert {:error, :no_issue} = Pipeline.approve_stage(task)
      task = Repo.get(Task, task.id)
      assert task.error =~ "has no GitHub issue"
    end

    test "fails when no design artifact exists for the task", %{project: project, issue: issue, task: task} do
      {:ok, workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Approve Stage Workspace 10512",
          external_id: "lin_ws_approve_stage_10512",
          token: "lin_api_token_approve_stage_10512",
          webhook_secret: "whsec_approve_stage_10512"
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_approve_stage_10507",
        "identifier" => "ISS-10507",
        "title" => "Approve Stage Issue 10507"
      })

      {:ok, issue} = Issues.capture_issue(system_scope(), project, "Approve Stage Issue 10507")

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :design,
          stage_state: :awaiting_approval
        })

      assert {:error, :no_design} = Pipeline.approve_stage(task)
      task = Repo.get(Task, task.id)
      assert task.error =~ "No design artifact found to publish"
    end

    test "fails when multiple directions exist but none is picked", %{project: project, issue: issue, task: task} do
      {:ok, workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Approve Stage Workspace 10513",
          external_id: "lin_ws_approve_stage_10513",
          token: "lin_api_token_approve_stage_10513",
          webhook_secret: "whsec_approve_stage_10513"
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_approve_stage_10508",
        "identifier" => "ISS-10508",
        "title" => "Approve Stage Issue 10508"
      })

      {:ok, issue} = Issues.capture_issue(system_scope(), project, "Approve Stage Issue 10508")

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :design,
          stage_state: :awaiting_approval
        })

      design_manifest_11002 =
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/design-11002",
          "version" => 1,
          "pickedKey" => nil,
          "directions" => [
            %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"},
            %{"key" => "dir-2", "title" => "Direction 2", "notes" => "Notes", "stillPath" => "dir-2.png"}
          ]
        })

      expect(File, :exists?, 3, fn _path -> true end)

      expect(File, :read, fn _path -> {:ok, design_manifest_11002} end)

      expect(File, :stat, 2, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

      expect(File, :read, 2, fn _path -> {:ok, "PNG_STILL"} end)

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_11002", url_probe: fn _url -> true end)

      assert {:error, :no_picked_direction} = Pipeline.approve_stage(task)
      task = Repo.get(Task, task.id)
      assert task.error =~ "No design direction has been picked to publish"
    end

    test "automatically uses single direction when picked_key is nil", %{project: project, issue: issue, task: task} do
      {:ok, workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Approve Stage Workspace 10514",
          external_id: "lin_ws_approve_stage_10514",
          token: "lin_api_token_approve_stage_10514",
          webhook_secret: "whsec_approve_stage_10514"
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_approve_stage_10509",
        "identifier" => "ISS-10509",
        "title" => "Approve Stage Issue 10509"
      })

      {:ok, issue} = Issues.capture_issue(system_scope(), project, "Approve Stage Issue 10509")

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :design,
          stage_state: :awaiting_approval
        })

      design_manifest_11003 =
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/design-11003",
          "version" => 1,
          "pickedKey" => nil,
          "directions" => [
            %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
          ]
        })

      expect(File, :exists?, 2, fn _path -> true end)

      expect(File, :read, fn _path -> {:ok, design_manifest_11003} end)

      expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

      expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

      mock_design_uploads(1)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_11003", url_probe: fn _url -> true end)

      LinearMock.mock_create_comment_success(%{"id" => "com_solo", "body" => "Solo comment"})

      assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(task)
    end

    test "handles publish failure when Linear comment creation fails", %{project: project, issue: issue, task: task} do
      {:ok, workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Approve Stage Workspace 10515",
          external_id: "lin_ws_approve_stage_10515",
          token: "lin_api_token_approve_stage_10515",
          webhook_secret: "whsec_approve_stage_10515"
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_approve_stage_10510",
        "identifier" => "ISS-10510",
        "title" => "Approve Stage Issue 10510"
      })

      {:ok, issue} = Issues.capture_issue(system_scope(), project, "Approve Stage Issue 10510")

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :design,
          stage_state: :awaiting_approval
        })

      design_manifest_11004 =
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/design-11004",
          "version" => 1,
          "pickedKey" => "dir-1",
          "directions" => [
            %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
          ]
        })

      expect(File, :exists?, 2, fn _path -> true end)

      expect(File, :read, fn _path -> {:ok, design_manifest_11004} end)

      expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

      expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

      mock_design_uploads(1)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_11004", url_probe: fn _url -> true end)

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Comment API error")
      end)

      assert {:error, {:publish_failed, msg}} = Pipeline.approve_stage(task)
      assert msg =~ "Failed to publish design"
      task = Repo.get(Task, task.id)
      assert task.error =~ "Failed to publish design"
    end

    test "determines next stage as ready_to_merge for unknown stage", %{task: task} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :merged,
          stage_state: :awaiting_approval
        })

      assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.approve_stage(task)
    end
  end
end

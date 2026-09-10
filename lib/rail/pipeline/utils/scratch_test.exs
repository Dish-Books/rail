defmodule Rail.Pipeline.Utils.ScratchTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.Scratch

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Scratch Workspace",
        external_id: "lin_ws_scratch",
        token: "lin_api_token_scratch",
        webhook_secret: "whsec_scratch"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Scratch Project 13501",
        github_repo: "org/scratch-13501",
        github_installation_id: 13_501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_scratch_13501",
        linear_team_key: "P13501",
        clone_path: "/tmp/repos/scratch-13501",
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
      "id" => "lin_scratch_1",
      "identifier" => "SCR-1",
      "title" => "Scratch Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Scratch Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_scratch_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "default_scratch_path constructs path from structs, strings, and RAIL_WORKSPACE_ROOT", %{
    project: project,
    task: task
  } do
    path1 = default_scratch_path(project, task)
    assert path1 =~ "#{project.id}/scratch/#{task.id}"

    path2 = default_scratch_path(project.id, task.id)
    assert path2 == path1

    System.put_env("RAIL_WORKSPACE_ROOT", "/custom/workspace")
    path3 = default_scratch_path(123, 456)
    assert path3 == "/custom/workspace/123/scratch/456"
    System.delete_env("RAIL_WORKSPACE_ROOT")
  end

  test "resolve_identifier extracts identifier from preloaded or un-preloaded issue", %{
    project: project,
    issue: _issue,
    task: task
  } do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13504",
      "identifier" => "ENG-101",
      "title" => "Scratch Issue 13504"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Scratch Issue 13504")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id
      })

    assert resolve_identifier(task) == "ENG-101"

    task_preloaded = Repo.preload(task, :issue)
    assert resolve_identifier(task_preloaded) == "ENG-101"

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_scratch_13502",
      "identifier" => "TSK-13502",
      "title" => "Task 13502"
    })

    {:ok, issue_13502} = Issues.capture_issue(system_scope(), project, "Task 13502")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_scratch_13502"})

    {:ok, task_no_issue} = Pipeline.bring_local(system_scope(), issue_13502)

    {:ok, task_no_issue} =
      Pipeline.update_task(system_scope(), task_no_issue.id, %{
        issue_id: nil
      })

    assert is_nil(resolve_identifier(task_no_issue))
    assert is_nil(resolve_identifier(nil))

    assert is_nil(resolve_identifier(%Task{issue_id: "iss_nonexistent"}))
  end

  test "handles stage normalization for string and unknown stages", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, %Task{}} = capture("product", task, scratch_dir)
    assert {:ok, %Task{}} = capture("unknown_stage", task, scratch_dir)
    assert {:ok, %Task{}} = capture(123, task, scratch_dir)
  end

  test "prepare creates subdirectories and writes initial ticket for product stage", %{
    project: project,
    issue: _issue,
    task: task
  } do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13505",
      "identifier" => "ENG-102",
      "title" => "Scratch Issue 13505"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Scratch Issue 13505")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        title: "Product Task",
        description: "Problem statement",
        stage: :product
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    assert File.dir?(Path.join(scratch_dir, "tickets"))
    assert File.dir?(Path.join(scratch_dir, "plans"))
    assert File.dir?(Path.join(scratch_dir, "design"))
    assert File.dir?(Path.join(scratch_dir, "qa"))
    assert File.dir?(Path.join(scratch_dir, "demo"))

    ticket_file = Path.join([scratch_dir, "tickets", "ENG-102.md"])
    assert File.exists?(ticket_file)
    assert File.read!(ticket_file) =~ "# Product Task\n\nProblem statement\n"
  end

  test "prepare for engineer writes plan from plans table to plan.md", %{project: project, issue: _issue, task: task} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13506",
      "identifier" => "ENG-103",
      "title" => "Scratch Issue 13506"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Scratch Issue 13506")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :engineer
      })

    # This test then reads the real filesystem, so capture the plan from a real dir.
    plan_dir = Path.join("/tmp", "rail_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plan_dir)
    File.write!(Path.join(plan_dir, "plan.md"), "## Implementation plan\nStep 1")
    on_exit(fn -> File.rm_rf(plan_dir) end)

    {:ok, _captured} = capture(:architect, task, plan_dir)

    {:ok, _plan} = Pipeline.get_plan(system_scope(), task)

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    plan_path = Path.join(scratch_dir, "plan.md")
    assert File.exists?(plan_path)
    assert File.read!(plan_path) == "## Implementation plan\nStep 1"

    id_plan_path = Path.join([scratch_dir, "plans", "ENG-103.md"])
    assert File.exists?(id_plan_path)
    assert File.read!(id_plan_path) == "## Implementation plan\nStep 1"
  end

  test "prepare for engineer extracts legacy plan from description when no plan in db", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: nil,
        stage: :engineer,
        description: "Ticket details\n\n## Implementation plan\nFallback steps"
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    plan_path = Path.join(scratch_dir, "plan.md")
    assert File.exists?(plan_path)
    assert File.read!(plan_path) =~ "Fallback steps"
  end

  test "prepare for engineer does nothing if no plan content exists", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: nil,
        stage: :engineer,
        description: "Only ticket details without plan"
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    refute File.exists?(Path.join(scratch_dir, "plan.md"))
  end

  test "prepare for engineer writes outstanding_reports.md when outstanding reports exist", %{task: task, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        outstanding_reports: [role.id]
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "Needs better tests"
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    reports_file = Path.join(scratch_dir, "outstanding_reports.md")
    assert File.exists?(reports_file)
    assert File.read!(reports_file) =~ "### Reviewer\n\nNeeds better tests"
  end

  test "prepare for design or architect materializes design if present", %{task: task} do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Scratch Workspace 13509",
        external_id: "lin_ws_scratch_13509",
        token: "lin_api_token_scratch_13509",
        webhook_secret: "whsec_scratch_13509"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: nil,
        stage: :design
      })

    %Design{}
    |> Design.changeset(%{
      task_id: task.id,
      version: 1,
      canvas_url: "https://canvas.example.com",
      picked_key: "dir_a",
      directions: [
        %{
          key: "dir_a",
          title: "Dir A",
          notes: "Notes A",
          still_url: ""
        }
      ]
    })
    |> Repo.insert!()

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    assert File.exists?(Path.join([scratch_dir, "design", "manifest.json"]))

    # Test architect stage with string stage
    task_arch = %{task | stage: :architect}
    scratch_dir2 = create_temp_git_repo()
    assert {:ok, ^scratch_dir2} = prepare(task_arch, scratch_dir2)
    assert File.exists?(Path.join([scratch_dir2, "design", "manifest.json"]))
  end

  test "prepare handles qa_lead and generic stage gracefully", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    task_generic = %{task | stage: :ready_to_merge}
    assert {:ok, ^scratch_dir} = prepare(task_generic, scratch_dir)
  end

  test "prepare for qa_lead materializes latest QA report into scratch/qa", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead
      })

    scratch_dir = create_temp_git_repo()

    {:ok, _qa} =
      %QaReport{}
      |> QaReport.changeset(%{
        task_id: task.id,
        commit: "qa_commit_123",
        session: %{"port" => 4000},
        rows: [
          %{
            id: "chk_lead",
            check: "Lead verify",
            result: :pass,
            severity: :cosmetic,
            artifacts: [
              %{name: "output.txt", kind: :text, text: "PASS EVIDENCE"}
            ]
          }
        ]
      })
      |> Repo.insert()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    assert File.exists?(Path.join([scratch_dir, "qa", "manifest.json"]))
    assert File.exists?(Path.join([scratch_dir, "qa", "output.txt"]))
    assert File.read!(Path.join([scratch_dir, "qa", "output.txt"])) == "PASS EVIDENCE"

    manifest = Jason.decode!(File.read!(Path.join([scratch_dir, "qa", "manifest.json"])))
    assert manifest["commit"] == "qa_commit_123"
  end

  test "capture for product updates ticket and processes split tickets", %{project: project, issue: _issue, task: task} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_104",
      "identifier" => "ENG-104",
      "title" => "Scratch Issue 13507"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Scratch Issue 13507")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :product,
        title: "Old Title",
        description: "Old Desc"
      })

    scratch_dir = create_temp_git_repo()
    tickets_dir = Path.join(scratch_dir, "tickets")
    File.mkdir_p!(tickets_dir)

    File.write!(
      Path.join(tickets_dir, "ENG-104.md"),
      "# Updated Title\n\nUpdated Description Body"
    )

    File.write!(
      Path.join(tickets_dir, "split-1.md"),
      "# Split Ticket 1\n\nSplit body 1"
    )

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_104",
      "identifier" => "ENG-104",
      "title" => "Updated Title",
      "description" => "Updated Description Body",
      "state" => %{"id" => "st_1", "name" => "In Progress", "type" => "started"},
      "url" => "https://linear.app/issue/ENG-104",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_1",
      "identifier" => "ENG-105",
      "title" => "Split Ticket 1",
      "description" => "Split body 1",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "url" => "https://linear.app/issue/ENG-105",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Task{title: "Updated Title", description: "Updated Description Body"}} =
             capture(:product, task, scratch_dir)
  end

  test "capture for architect captures plan from plan.md", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect
      })

    scratch_dir = create_temp_git_repo()

    File.write!(Path.join(scratch_dir, "plan.md"), "## Implementation plan\nStep A\nStep B")

    assert {:ok, %Task{id: task_id}} = capture(:architect, task, scratch_dir)

    plan = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert %Plan{content: "## Implementation plan\nStep A\nStep B"} = plan
  end

  test "capture for architect captures plan from plans/identifier.md if plan.md missing", %{
    project: project,
    issue: _issue,
    task: task
  } do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13508",
      "identifier" => "ENG-106",
      "title" => "Scratch Issue 13508"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Scratch Issue 13508")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :architect
      })

    scratch_dir = create_temp_git_repo()
    plans_dir = Path.join(scratch_dir, "plans")
    File.mkdir_p!(plans_dir)

    File.write!(Path.join(plans_dir, "ENG-106.md"), "## Implementation plan\nFrom subfolder")

    assert {:ok, %Task{id: task_id}} = capture(:architect, task, scratch_dir)

    plan = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert %Plan{content: "## Implementation plan\nFrom subfolder"} = plan
  end

  test "capture delegates to artifacts for design, qa, demo when manifests exist", %{task: task} do
    # Artifact capture only posts to Linear when the task has an issue.
    {:ok, task} = Pipeline.update_task(system_scope(), task.id, %{issue_id: nil})

    scratch_dir = create_temp_git_repo()

    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    File.write!(Path.join(design_dir, "manifest.json"), ~s({"version": 1, "canvasUrl": "https://example.com"}))

    assert {:ok, %Task{}} = capture(:design, task, scratch_dir)

    qa_dir = Path.join(scratch_dir, "qa")
    File.mkdir_p!(qa_dir)
    File.write!(Path.join(qa_dir, "manifest.json"), ~s({"commit": "abc", "session": {}, "rows": []}))

    assert {:ok, %Task{}} = capture(:qa, task, scratch_dir)

    scratch_dir_direct = create_temp_git_repo()
    File.write!(Path.join(scratch_dir_direct, "manifest.json"), ~s({"commit": "dir_qa", "session": {}, "rows": []}))
    assert {:ok, %Task{}} = capture(:qa, task, scratch_dir_direct)

    demo_dir = Path.join(scratch_dir, "demo")
    File.mkdir_p!(demo_dir)

    File.write!(
      Path.join(demo_dir, "manifest.json"),
      ~s({"version": 1, "outcome": "recorded", "note": "ok", "segments": []})
    )

    assert {:ok, %Task{}} = capture(:demo, task, scratch_dir)
  end

  test "capture for unhandled stage or missing files does nothing", %{task: task} do
    scratch_dir = create_temp_git_repo()

    assert {:ok, %Task{}} = capture(:engineer, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:review, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:design, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:qa, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:demo, task, scratch_dir)
  end
end

defmodule Rail.Pipeline.Utils.CaptureScratchTest do
  use Rail.DataCase, async: true

  import Ecto.Query
  import Rail.Pipeline.Utils.CaptureScratch

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

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
        default_branch: "main",
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
            backend_id: backend.id,
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

    {:ok, issue} = Issues.create_issue(project, %{description: "Scratch Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "capture_scratch for product updates ticket and processes split tickets", %{
    project: project,
    issue: _issue,
    task: task
  } do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_104",
      "identifier" => "ENG-104",
      "title" => "Scratch Issue 13507"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Scratch Issue 13507"})

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [title: "Old Title", description: "Old Desc"])

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :product
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

    assert {:ok, %Task{}} = capture_scratch(:product, %{task | scratch_path: scratch_dir})

    assert %Issue{title: "Updated Title", description: "Updated Description Body"} =
             Repo.get!(Issue, task.issue_id)
  end

  test "capture_scratch for architect captures plan from plan.md", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :architect
      })

    scratch_dir = create_temp_git_repo()

    File.write!(Path.join(scratch_dir, "plan.md"), "## Implementation plan\nStep A\nStep B")

    assert {:ok, %Task{id: task_id}} = capture_scratch(:architect, %{task | scratch_path: scratch_dir})

    plan = Repo.one(from p in ImplementationPlan, where: p.task_id == ^task_id)
    assert %ImplementationPlan{content: "## Implementation plan\nStep A\nStep B"} = plan
  end

  test "capture_scratch for architect captures plan from plans/identifier.md if plan.md missing", %{
    project: project,
    issue: _issue,
    task: task
  } do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13508",
      "identifier" => "ENG-106",
      "title" => "Scratch Issue 13508"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Scratch Issue 13508"})

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :architect
      })

    scratch_dir = create_temp_git_repo()
    plans_dir = Path.join(scratch_dir, "plans")
    File.mkdir_p!(plans_dir)

    File.write!(Path.join(plans_dir, "ENG-106.md"), "## Implementation plan\nFrom subfolder")

    assert {:ok, %Task{id: task_id}} = capture_scratch(:architect, %{task | scratch_path: scratch_dir})

    plan = Repo.one(from p in ImplementationPlan, where: p.task_id == ^task_id)
    assert %ImplementationPlan{content: "## Implementation plan\nFrom subfolder"} = plan
  end

  test "capture_scratch delegates to artifacts for qa, demo when manifests exist", %{task: task} do
    # Artifact capture only posts to Linear when the task has an issue.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    scratch_dir = create_temp_git_repo()

    qa_dir = Path.join(scratch_dir, "qa")
    File.mkdir_p!(qa_dir)
    File.write!(Path.join(qa_dir, "manifest.json"), ~s({"commit": "abc", "session": {}, "rows": []}))

    assert {:ok, %Task{}} = capture_scratch(:qa, %{task | scratch_path: scratch_dir})

    scratch_dir_direct = create_temp_git_repo()
    File.write!(Path.join(scratch_dir_direct, "manifest.json"), ~s({"commit": "dir_qa", "session": {}, "rows": []}))
    assert {:ok, %Task{}} = capture_scratch(:qa, %{task | scratch_path: scratch_dir_direct})

    demo_dir = Path.join(scratch_dir, "demo")
    File.mkdir_p!(demo_dir)

    File.write!(
      Path.join(demo_dir, "manifest.json"),
      ~s({"version": 1, "outcome": "recorded", "note": "ok", "segments": []})
    )

    assert {:ok, %Task{}} = capture_scratch(:demo, %{task | scratch_path: scratch_dir})
  end

  test "capture_scratch for unhandled stage or missing files does nothing", %{task: task} do
    scratch_dir = create_temp_git_repo()

    assert {:ok, %Task{}} = capture_scratch(:engineer, %{task | scratch_path: scratch_dir})
    assert {:ok, %Task{}} = capture_scratch(:review, %{task | scratch_path: scratch_dir})
    assert {:ok, %Task{}} = capture_scratch(:qa, %{task | scratch_path: scratch_dir})
    assert {:ok, %Task{}} = capture_scratch(:demo, %{task | scratch_path: scratch_dir})
  end
end

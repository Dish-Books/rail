defmodule Rail.Pipeline.Utils.PrepareScratchTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.PrepareScratch

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
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

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "prepare_scratch creates subdirectories and writes initial ticket for product stage", %{
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

    {:ok, issue} =
      issue
      |> Issue.changeset(%{title: "Product Task", description: "Problem statement"}, project.id)
      |> Repo.update()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{issue_id: issue.id, stage: :product})

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)

    assert File.dir?(Path.join(scratch_dir, "tickets"))
    assert File.dir?(Path.join(scratch_dir, "plans"))
    assert File.dir?(Path.join(scratch_dir, "design"))
    assert File.dir?(Path.join(scratch_dir, "qa"))
    assert File.dir?(Path.join(scratch_dir, "demo"))

    ticket_file = Path.join([scratch_dir, "tickets", "ENG-102.md"])
    assert File.exists?(ticket_file)
    assert File.read!(ticket_file) =~ "---\ntitle: Product Task\n"
    assert File.read!(ticket_file) =~ "\n---\n\nProblem statement\n"
  end

  test "prepare_scratch for engineer writes plan from plans table to plan.md", %{
    project: project,
    issue: _issue,
    task: task
  } do
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

    %Plan{}
    |> Plan.changeset(%{content: "## Implementation plan\nStep 1", captured_at: DateTime.utc_now()}, task.id)
    |> Repo.insert!()

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)

    plan_path = Path.join(scratch_dir, "plan.md")
    assert File.exists?(plan_path)
    assert File.read!(plan_path) == "## Implementation plan\nStep 1"

    id_plan_path = Path.join([scratch_dir, "plans", "ENG-103.md"])
    assert File.exists?(id_plan_path)
    assert File.read!(id_plan_path) == "## Implementation plan\nStep 1"
  end

  test "prepare_scratch for engineer does nothing if no plan content exists", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: nil,
        stage: :engineer
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)
    refute File.exists?(Path.join(scratch_dir, "plan.md"))
  end

  test "prepare_scratch for engineer writes outstanding_reports.md when outstanding reports exist", %{
    task: task,
    roles: roles
  } do
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

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)
    reports_file = Path.join(scratch_dir, "outstanding_reports.md")
    assert File.exists?(reports_file)
    assert File.read!(reports_file) =~ "### Reviewer\n\nNeeds better tests"
  end

  test "prepare_scratch for design or architect materializes design if present", %{task: task} do
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

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)
    assert File.exists?(Path.join([scratch_dir, "design", "manifest.json"]))

    # Test architect stage with string stage
    task_arch = %{task | stage: :architect}
    scratch_dir2 = create_temp_git_repo()
    assert {:ok, ^scratch_dir2} = prepare_scratch(task_arch, scratch_dir2)
    assert File.exists?(Path.join([scratch_dir2, "design", "manifest.json"]))
  end

  test "prepare_scratch handles qa_lead and generic stage gracefully", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead
      })

    scratch_dir = create_temp_git_repo()

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)

    task_generic = %{task | stage: :ready_to_merge}
    assert {:ok, ^scratch_dir} = prepare_scratch(task_generic, scratch_dir)
  end

  test "prepare_scratch for qa_lead materializes latest QA report into scratch/qa", %{task: task} do
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

    assert {:ok, ^scratch_dir} = prepare_scratch(task, scratch_dir)
    assert File.exists?(Path.join([scratch_dir, "qa", "manifest.json"]))
    assert File.exists?(Path.join([scratch_dir, "qa", "output.txt"]))
    assert File.read!(Path.join([scratch_dir, "qa", "output.txt"])) == "PASS EVIDENCE"

    manifest = Jason.decode!(File.read!(Path.join([scratch_dir, "qa", "manifest.json"])))
    assert manifest["commit"] == "qa_commit_123"
  end
end

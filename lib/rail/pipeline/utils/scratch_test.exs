defmodule Rail.Pipeline.Utils.ScratchTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.Scratch

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  test "default_scratch_path constructs path from structs, strings, and AXIS_WORKSPACE_ROOT" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id})

    path1 = default_scratch_path(project, task)
    assert path1 =~ "#{project.id}/scratch/#{task.id}"

    path2 = default_scratch_path(project.id, task.id)
    assert path2 == path1

    System.put_env("AXIS_WORKSPACE_ROOT", "/custom/workspace")
    path3 = default_scratch_path(123, 456)
    assert path3 == "/custom/workspace/123/scratch/456"
    System.delete_env("AXIS_WORKSPACE_ROOT")
  end

  test "resolve_identifier extracts identifier from preloaded or un-preloaded issue" do
    project = create_test_project()
    issue = create_test_issue(%{project_id: project.id, identifier: "ENG-101"})
    task = create_test_task(%{project_id: project.id, issue_id: issue.id})

    assert resolve_identifier(task) == "ENG-101"

    task_preloaded = Repo.preload(task, :issue)
    assert resolve_identifier(task_preloaded) == "ENG-101"

    task_no_issue = create_test_task(%{project_id: project.id, issue_id: nil})
    assert is_nil(resolve_identifier(task_no_issue))
    assert is_nil(resolve_identifier(nil))

    assert is_nil(resolve_identifier(%Task{issue_id: "iss_nonexistent"}))
  end

  test "handles stage normalization for string and unknown stages" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :product})
    scratch_dir = create_temp_scratch_dir()

    assert {:ok, %Task{}} = capture("product", task, scratch_dir)
    assert {:ok, %Task{}} = capture("unknown_stage", task, scratch_dir)
    assert {:ok, %Task{}} = capture(123, task, scratch_dir)
  end

  test "prepare creates subdirectories and writes initial ticket for product stage" do
    project = create_test_project()
    issue = create_test_issue(%{project_id: project.id, identifier: "ENG-102"})

    task =
      create_test_task(%{
        project_id: project.id,
        issue_id: issue.id,
        title: "Product Task",
        description: "Problem statement",
        stage: :product
      })

    scratch_dir = create_temp_scratch_dir()

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

  test "prepare for engineer writes plan from plans table to plan.md" do
    project = create_test_project()
    issue = create_test_issue(%{project_id: project.id, identifier: "ENG-103"})

    task =
      create_test_task(%{
        project_id: project.id,
        issue_id: issue.id,
        stage: :engineer
      })

    create_test_plan(%{task_id: task.id, content: "## Implementation plan\nStep 1"})

    scratch_dir = create_temp_scratch_dir()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    plan_path = Path.join(scratch_dir, "plan.md")
    assert File.exists?(plan_path)
    assert File.read!(plan_path) == "## Implementation plan\nStep 1"

    id_plan_path = Path.join([scratch_dir, "plans", "ENG-103.md"])
    assert File.exists?(id_plan_path)
    assert File.read!(id_plan_path) == "## Implementation plan\nStep 1"
  end

  test "prepare for engineer extracts legacy plan from description when no plan in db" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        issue_id: nil,
        stage: :engineer,
        description: "Ticket details\n\n## Implementation plan\nFallback steps"
      })

    scratch_dir = create_temp_scratch_dir()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    plan_path = Path.join(scratch_dir, "plan.md")
    assert File.exists?(plan_path)
    assert File.read!(plan_path) =~ "Fallback steps"
  end

  test "prepare for engineer does nothing if no plan content exists" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        issue_id: nil,
        stage: :engineer,
        description: "Only ticket details without plan"
      })

    scratch_dir = create_temp_scratch_dir()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    refute File.exists?(Path.join(scratch_dir, "plan.md"))
  end

  test "prepare for design or architect materializes design if present" do
    Repo.insert!(Rail.Projects.Schemas.LinearWorkspace.factory())
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
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

    scratch_dir = create_temp_scratch_dir()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)
    assert File.exists?(Path.join([scratch_dir, "design", "manifest.json"]))

    # Test architect stage with string stage
    task_arch = %{task | stage: :architect}
    scratch_dir2 = create_temp_scratch_dir()
    assert {:ok, ^scratch_dir2} = prepare(task_arch, scratch_dir2)
    assert File.exists?(Path.join([scratch_dir2, "design", "manifest.json"]))
  end

  test "prepare handles qa_lead and generic stage gracefully" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :qa_lead})
    scratch_dir = create_temp_scratch_dir()

    assert {:ok, ^scratch_dir} = prepare(task, scratch_dir)

    task_generic = %{task | stage: :ready_to_merge}
    assert {:ok, ^scratch_dir} = prepare(task_generic, scratch_dir)
  end

  test "capture for product updates ticket and processes split tickets" do
    project = create_test_project()
    issue = create_test_issue(%{project_id: project.id, identifier: "ENG-104", external_id: "lin_104"})

    task =
      create_test_task(%{
        project_id: project.id,
        issue_id: issue.id,
        stage: :product,
        title: "Old Title",
        description: "Old Desc"
      })

    scratch_dir = create_temp_scratch_dir()
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

  test "capture for architect captures plan from plan.md" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :architect})
    scratch_dir = create_temp_scratch_dir()

    File.write!(Path.join(scratch_dir, "plan.md"), "## Implementation plan\nStep A\nStep B")

    assert {:ok, %Task{id: task_id}} = capture(:architect, task, scratch_dir)

    plan = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert %Plan{content: "## Implementation plan\nStep A\nStep B"} = plan
  end

  test "capture for architect captures plan from plans/identifier.md if plan.md missing" do
    project = create_test_project()
    issue = create_test_issue(%{project_id: project.id, identifier: "ENG-106"})
    task = create_test_task(%{project_id: project.id, issue_id: issue.id, stage: :architect})
    scratch_dir = create_temp_scratch_dir()
    plans_dir = Path.join(scratch_dir, "plans")
    File.mkdir_p!(plans_dir)

    File.write!(Path.join(plans_dir, "ENG-106.md"), "## Implementation plan\nFrom subfolder")

    assert {:ok, %Task{id: task_id}} = capture(:architect, task, scratch_dir)

    plan = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert %Plan{content: "## Implementation plan\nFrom subfolder"} = plan
  end

  test "capture delegates to artifacts for design, qa, demo when manifests exist" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id})
    scratch_dir = create_temp_scratch_dir()

    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    File.write!(Path.join(design_dir, "manifest.json"), ~s({"version": 1, "canvasUrl": "https://example.com"}))

    assert {:ok, %Task{}} = capture(:design, task, scratch_dir)

    qa_dir = Path.join(scratch_dir, "qa")
    File.mkdir_p!(qa_dir)
    File.write!(Path.join(qa_dir, "manifest.json"), ~s({"commit": "abc", "session": {}, "rows": []}))

    assert {:ok, %Task{}} = capture(:qa, task, scratch_dir)

    demo_dir = Path.join(scratch_dir, "demo")
    File.mkdir_p!(demo_dir)

    File.write!(
      Path.join(demo_dir, "manifest.json"),
      ~s({"version": 1, "outcome": "recorded", "note": "ok", "segments": []})
    )

    assert {:ok, %Task{}} = capture(:demo, task, scratch_dir)
  end

  test "capture for unhandled stage or missing files does nothing" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id})
    scratch_dir = create_temp_scratch_dir()

    assert {:ok, %Task{}} = capture(:engineer, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:review, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:design, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:qa, task, scratch_dir)
    assert {:ok, %Task{}} = capture(:demo, task, scratch_dir)
  end
end

defmodule Rail.Pipeline.Schemas.TaskTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Users.Schemas.User

  test "factory builds a valid task struct" do
    assert %Task{
             project_id: "prj_" <> _id,
             title: "Task " <> _title,
             stage: :product,
             stage_state: :queued,
             is_rebasing: false,
             rework_cycles: 0,
             rework_budget_base: 0,
             rework_cycles_by_gate: %{},
             outstanding_reports: [],
             viewed_diff_files: []
           } = Task.factory()
  end

  test "changeset validates required fields" do
    assert %{
             project_id: ["can't be blank"],
             title: ["can't be blank"]
           } = errors_on(Task.changeset(%Task{}, %{}))

    assert %{
             stage: ["can't be blank"],
             stage_state: ["can't be blank"]
           } = errors_on(Task.changeset(%Task{}, %{stage: nil, stage_state: nil}))
  end

  test "changeset accepts valid attributes and sets defaults" do
    project = create_test_project()

    attrs = %{
      title: "Core Pipeline Feature",
      description: "Build pipeline core logic",
      worktree_name: "core-feature",
      pr_number: 101,
      pr_url: "https://github.com/example/repo/pull/101",
      mergeability: :mergeable,
      pr_is_draft: true,
      is_rebasing: false,
      rework_cycles: 1,
      rework_budget_base: 0,
      rework_cycles_by_gate: %{"rol_1" => 1},
      outstanding_reports: ["rol_1"],
      viewed_diff_files: ["lib/foo.ex"]
    }

    changeset = Task.changeset(%Task{}, attrs, project.id)

    assert changeset.valid?
    assert get_field(changeset, :stage) == :product
    assert get_field(changeset, :stage_state) == :queued
    assert get_field(changeset, :pr_number) == 101
    assert get_field(changeset, :mergeability) == :mergeable
  end

  test "changeset validates enum types" do
    project = create_test_project()

    attrs = %{
      title: "Task with Invalid Enums",
      stage: "invalid_stage",
      stage_state: "invalid_stage_state",
      mergeability: "invalid_mergeability",
      stage_state_before_rebase: "invalid_before_rebase"
    }

    assert %{
             stage: ["is invalid"],
             stage_state: ["is invalid"],
             mergeability: ["is invalid"],
             stage_state_before_rebase: ["is invalid"]
           } = errors_on(Task.changeset(%Task{}, attrs, project.id))
  end

  test "ignores project_id passed in attrs to prevent unverified overrides" do
    project1 = create_test_project()
    other_project_id = "prj_000000000000000000000000"

    attrs = %{
      title: "Protected Task",
      project_id: other_project_id
    }

    changeset = Task.changeset(%Task{}, attrs, project1.id)
    assert get_field(changeset, :project_id) == project1.id
  end

  test "validates foreign key on project_id" do
    assert {:error, %{errors: [project_id: {"does not exist", _details}]}} =
             %Task{}
             |> Task.changeset(%{title: "Missing Project Task"}, "prj_000000000000000000000000")
             |> Repo.insert()
  end

  test "preloads belongs_to project, issue, and owner_user" do
    %Project{id: project_id} = project = create_test_project()
    %User{id: user_id} = user = Repo.insert!(User.factory())
    %Issue{id: issue_id} = issue = Repo.insert!(Issue.changeset(Issue.factory(), %{}, project.id))

    task =
      Repo.insert!(
        Task.changeset(
          %Task{},
          %{
            title: "Preload Task",
            issue_id: issue.id,
            owner_user_id: user.id
          },
          project.id
        )
      )

    preloaded = Repo.preload(task, [:project, :issue, :owner_user])

    assert %Task{
             project: %Project{id: ^project_id},
             issue: %Issue{id: ^issue_id},
             owner_user: %User{id: ^user_id}
           } = preloaded
  end

  test "preloads has_many questions, plans, role_runs, and designs" do
    %Task{id: task_id} = task = create_test_task()
    _question = create_test_question(%{task_id: task.id})
    _plan = create_test_plan(%{task_id: task.id})
    _role_run = create_test_role_run(%{task_id: task.id})
    _design = create_test_design(%{task_id: task.id})

    preloaded = Repo.preload(task, [:questions, :plans, :role_runs, :designs])

    assert %Task{
             questions: [%Question{task_id: ^task_id}],
             plans: [%Plan{task_id: ^task_id}],
             role_runs: [%RoleRun{task_id: ^task_id}],
             designs: [%Design{task_id: ^task_id}]
           } = preloaded
  end

  test "busy?/1 helper" do
    idle = %Task{stage_state: :queued, active_chat_role_id: nil, id: nil}
    refute Task.busy?(idle)

    running_stage = %Task{stage_state: :running, active_chat_role_id: nil, id: nil}
    assert Task.busy?(running_stage)

    active_chat = %Task{stage_state: :queued, active_chat_role_id: "rol_123", id: nil}
    assert Task.busy?(active_chat)

    refute Task.busy?(nil)
  end

  describe "uses_design?/1,2" do
    test "returns true when task is in :product or :design stage" do
      assert Task.uses_design?(%Task{stage: :product})
      assert Task.uses_design?(%Task{stage: :design})
    end

    test "returns true when role_runs list includes designer run" do
      task = %Task{id: "tsk_1", project_id: "prj_1", stage: :architect}

      assert Task.uses_design?(task, [%{role_id: "designer", task_id: "tsk_1"}])
      assert Task.uses_design?(task, [%{role: %{stage: :design}, task_id: "tsk_1"}])
      refute Task.uses_design?(task, [%{role_id: "engineer", task_id: "tsk_1"}])
    end

    test "checks database role_runs when task has advanced past design" do
      project = create_test_project()
      designer = create_test_role(%{project_id: project.id, stage: :design})
      task_with_run = create_test_task(%{project_id: project.id, stage: :architect})
      task_without_run = create_test_task(%{project_id: project.id, stage: :architect})

      _run = create_test_role_run(%{task_id: task_with_run.id, role_id: designer.id})

      assert Task.uses_design?(task_with_run)
      refute Task.uses_design?(task_without_run)

      # role_runs with role_id matching DB designer role
      assert Task.uses_design?(task_with_run, [%{role_id: designer.id, task_id: task_with_run.id}])

      # role run without designer role
      refute Task.uses_design?(task_with_run, [%{task_id: task_with_run.id, role_id: nil}])

      # project with no designer role in database
      project_no_designer = create_test_project()
      task_no_designer = create_test_task(%{project_id: project_no_designer.id, stage: :architect})
      refute Task.uses_design?(task_no_designer)
    end

    test "returns false for invalid inputs" do
      refute Task.uses_design?(nil)
      refute Task.uses_design?(%{})
      refute Task.uses_design?(%Task{stage: :architect})
    end
  end
end

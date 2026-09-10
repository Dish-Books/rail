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
             viewed_diff_files: %{}
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

  describe "schema enums, accessors, and stage lifecycle helpers" do
    test "stages/0, stage_states/0, mergeabilities/0 return expected lists" do
      assert length(Task.stages()) == 10
      assert :product in Task.stages()
      assert :merged in Task.stages()

      assert length(Task.stage_states()) == 11
      assert :queued in Task.stage_states()
      assert :blocked in Task.stage_states()

      assert :clean in Task.mergeabilities()
      assert :mergeable in Task.mergeabilities()
      assert :conflicting in Task.mergeabilities()
      assert :blocked in Task.mergeabilities()
      assert :unknown in Task.mergeabilities()
    end

    test "next_stage/1 walks the pipeline sequence correctly" do
      assert Task.next_stage(:product) == :design
      assert Task.next_stage(:design) == :architect
      assert Task.next_stage(:architect) == :engineer
      assert Task.next_stage(:engineer) == :review
      assert Task.next_stage(:review) == :qa
      assert Task.next_stage(:qa) == :qa_lead
      assert Task.next_stage(:qa_lead) == :demo
      assert Task.next_stage(:demo) == :ready_to_merge
      assert Task.next_stage(:ready_to_merge) == :merged
      assert is_nil(Task.next_stage(:merged))
      assert is_nil(Task.next_stage(:unknown))
    end

    test "prev_stage/1 and previous_stage/1 walk backwards" do
      assert is_nil(Task.prev_stage(:product))
      assert Task.prev_stage(:design) == :product
      assert Task.prev_stage(:architect) == :design
      assert Task.prev_stage(:engineer) == :architect
      assert Task.prev_stage(:review) == :engineer
      assert Task.prev_stage(:qa) == :review
      assert Task.prev_stage(:qa_lead) == :qa
      assert Task.prev_stage(:demo) == :qa_lead
      assert Task.prev_stage(:ready_to_merge) == :demo
      assert Task.prev_stage(:merged) == :ready_to_merge
      assert is_nil(Task.prev_stage(:unknown))

      assert Task.previous_stage(:design) == :product
      assert is_nil(Task.previous_stage(:product))
    end

    test "advanceable?/1 identifies stages that can progress" do
      for stage <- [:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo, :ready_to_merge] do
        assert Task.advanceable?(stage)
      end

      refute Task.advanceable?(:merged)
      refute Task.advanceable?(:other)
      refute Task.advanceable?("product")
    end

    test "gate?/1 identifies review and qa gates" do
      assert Task.gate?(:review)
      assert Task.gate?(:qa)
      assert Task.gate?(:qa_lead)
      refute Task.gate?(:engineer)
      refute Task.gate?(:merged)
      refute Task.gate?(nil)
      refute Task.gate?("qa")
      refute Task.gate?(123)
    end

    test "terminal_stage?/1 and terminal?/1 identify merged stage" do
      assert Task.terminal_stage?(:merged)
      refute Task.terminal_stage?(:product)
      refute Task.terminal_stage?(:ready_to_merge)
      refute Task.terminal_stage?(nil)
      refute Task.terminal_stage?("merged")
      refute Task.terminal_stage?(123)

      assert Task.terminal?(:merged)
      refute Task.terminal?(:engineer)
    end

    test "stage_index/1 and index/1 return zero-based pipeline indices" do
      assert Task.stage_index(:product) == 0
      assert Task.stage_index(:design) == 1
      assert Task.stage_index(:architect) == 2
      assert Task.stage_index(:engineer) == 3
      assert Task.stage_index(:review) == 4
      assert Task.stage_index(:qa) == 5
      assert Task.stage_index(:qa_lead) == 6
      assert Task.stage_index(:demo) == 7
      assert Task.stage_index(:ready_to_merge) == 8
      assert Task.stage_index(:merged) == 9
      assert is_nil(Task.stage_index(:unknown))
      assert is_nil(Task.stage_index(123))

      assert Task.index(:product) == 0
      assert Task.index(:merged) == 9
      assert is_nil(Task.index(:invalid))
    end

    test "before?/2 and after?/2 compare pipeline stage positions" do
      assert Task.before?(:product, :design)
      assert Task.before?(:architect, :merged)
      refute Task.before?(:design, :product)
      refute Task.before?(:product, :invalid)
      refute Task.before?(:invalid, :product)
      refute Task.before?(nil, :design)
      refute Task.before?("product", "design")
      refute Task.before?(123, 456)

      assert Task.after?(:design, :product)
      assert Task.after?(:merged, :ready_to_merge)
      refute Task.after?(:product, :design)
      refute Task.after?(:design, :invalid)
      refute Task.after?(:invalid, :design)
      refute Task.after?("design", "product")
      refute Task.after?(123, 456)
    end

    test "stage_label/1 returns human labels for stages" do
      assert Task.stage_label(:product) == "Product"
      assert Task.stage_label(:design) == "Design"
      assert Task.stage_label(:architect) == "Architect"
      assert Task.stage_label(:engineer) == "Engineer"
      assert Task.stage_label(:review) == "Review"
      assert Task.stage_label(:qa) == "QA"
      assert Task.stage_label(:qa_lead) == "QA Lead"
      assert Task.stage_label(:demo) == "Demo"
      assert Task.stage_label(:ready_to_merge) == "Ready to merge"
      assert Task.stage_label(:merged) == "Merged"
      assert is_nil(Task.stage_label(:invalid))
      assert is_nil(Task.stage_label(nil))
      assert is_nil(Task.stage_label(123))
    end

    test "cast_stage/1 parses atoms and binary strings" do
      assert {:ok, :product} = Task.cast_stage(:product)
      assert {:ok, :design} = Task.cast_stage("design")
      assert {:ok, :merged} = Task.cast_stage("merged")
      assert :error = Task.cast_stage(:invalid)
      assert :error = Task.cast_stage("invalid")
      assert :error = Task.cast_stage(nil)
      assert :error = Task.cast_stage(123)
    end

    test "paused?, running?, and queued? predicate helpers for atoms and Task structs" do
      # paused?
      assert Task.paused?(:paused_question)
      assert Task.paused?(:paused_chat)
      assert Task.paused?(:blocked)
      refute Task.paused?(:running)
      refute Task.paused?(:idle)
      assert Task.paused?(%Task{stage_state: :blocked})
      refute Task.paused?(%Task{stage_state: :running})
      refute Task.paused?(nil)
      refute Task.paused?("running")
      refute Task.paused?(123)

      # running?
      assert Task.running?(:running)
      refute Task.running?(:queued)
      assert Task.running?(%Task{stage_state: :running})
      refute Task.running?(%Task{stage_state: :queued})
      refute Task.running?(nil)
      refute Task.running?("running")
      refute Task.running?(123)

      # queued?
      assert Task.queued?(:queued)
      refute Task.queued?(:running)
      assert Task.queued?(%Task{stage_state: :queued})
      refute Task.queued?(%Task{stage_state: :running})
      refute Task.queued?(nil)
      refute Task.queued?("queued")
      refute Task.queued?(123)
    end

    test "awaiting_approval?, active?, and terminal_state? predicate helpers for atoms and Task structs" do
      # awaiting_approval?
      assert Task.awaiting_approval?(:awaiting_approval)
      refute Task.awaiting_approval?(:running)
      assert Task.awaiting_approval?(%Task{stage_state: :awaiting_approval})
      refute Task.awaiting_approval?(%Task{stage_state: :running})
      refute Task.awaiting_approval?(nil)
      refute Task.awaiting_approval?("awaiting")
      refute Task.awaiting_approval?(123)

      # active?
      assert Task.active?(:running)
      assert Task.active?(:paused_chat)
      refute Task.active?(:idle)
      refute Task.active?(:queued)
      assert Task.active?(%Task{stage_state: :running})
      assert Task.active?(%Task{stage_state: :paused_chat})
      refute Task.active?(%Task{stage_state: :idle})
      refute Task.active?(nil)
      refute Task.active?("running")
      refute Task.active?(123)

      # terminal_state?
      assert Task.terminal_state?(:failed)
      assert Task.terminal_state?(:canceled)
      refute Task.terminal_state?(:running)
      assert Task.terminal_state?(%Task{stage_state: :failed})
      refute Task.terminal_state?(%Task{stage_state: :running})
      refute Task.terminal_state?(nil)
      refute Task.terminal_state?("failed")
      refute Task.terminal_state?(123)
    end
  end
end

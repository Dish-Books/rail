defmodule Rail.Pipeline.Schemas.TaskTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CaptureScratch
  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.Run
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Task Schema Workspace",
        external_id: "lin_ws_task_schema",
        token: "lin_api_token_task_schema",
        webhook_secret: "whsec_task_schema"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Schema Project 12601",
        github_repo: "org/task-schema-12601",
        github_installation_id: 12_601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_task_schema_12601",
        linear_team_key: "P12601",
        default_branch: "main",
        clone_path: "/tmp/repos/task-schema-12601",
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
      "id" => "lin_task_schema_1",
      "identifier" => "TSK-1",
      "title" => "Task Schema Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Task Schema Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "changeset validates required fields" do
    assert %{project_id: ["can't be blank"]} = errors_on(Task.changeset(%Task{}, %{}))

    assert %{
             stage: ["can't be blank"]
           } = errors_on(Task.changeset(%Task{}, %{stage: nil}))
  end

  test "changeset accepts valid attributes and sets defaults", %{project: project} do
    attrs = %{
      title: "Core Pipeline Feature",
      description: "Build pipeline core logic",
      worktree_name: "core-feature",
      worktree_path: "/tmp/repos/task-schema/.worktrees/core-feature",
      scratch_path: Path.join(System.tmp_dir!(), "rail_test_scratch_#{System.unique_integer([:positive])}"),
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
    assert get_field(changeset, :pr_number) == 101
    assert get_field(changeset, :mergeability) == :mergeable
  end

  test "changeset validates enum types", %{project: project} do
    attrs = %{
      title: "Task with Invalid Enums",
      stage: "invalid_stage",
      mergeability: "invalid_mergeability"
    }

    assert %{
             stage: ["is invalid"],
             mergeability: ["is invalid"]
           } = errors_on(Task.changeset(%Task{}, attrs, project.id))
  end

  test "ignores project_id passed in attrs to prevent unverified overrides", %{task: _task} do
    {:ok, project1} =
      Projects.create_project(system_scope(), %{
        name: "Task Schema Project 12604",
        github_repo: "org/task-schema-12604",
        github_installation_id: 12_604,
        linear_team_id: "team_task_schema_12604",
        linear_team_key: "P12604",
        default_branch: "main",
        clone_path: "/tmp/repos/task-schema-12604",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

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
             |> Task.changeset(
               %{
                 title: "Missing Project Task",
                 worktree_name: "missing",
                 worktree_path: "/tmp/missing",
                 scratch_path: "/tmp/scratch"
               },
               "prj_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to project, issue, and owner_user", %{project: _project, issue: _issue, task: _task} do
    {:ok, %Project{id: project_id} = project} =
      Projects.create_project(system_scope(), %{
        name: "Task Schema Project 12605",
        github_repo: "org/task-schema-12605",
        github_installation_id: 12_605,
        linear_team_id: "team_task_schema_12605",
        linear_team_key: "P12605",
        default_branch: "main",
        clone_path: "/tmp/repos/task-schema-12605",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, %User{id: user_id} = user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_schema_12610",
        login: "task_schema_user_12610",
        email: "task_schema_user_12610@example.com",
        github_token: "gho_token_12610"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_schema_12611",
      "identifier" => "ISS-12611",
      "title" => "Task Schema Issue 12611"
    })

    {:ok, %Issue{id: issue_id} = issue} = Issues.capture_issue(system_scope(), project, "Task Schema Issue 12611")

    {:ok, _issue} = issue |> Issue.changeset(%{owner_user_id: user.id}, project.id) |> Repo.update()

    task =
      Repo.insert!(
        Task.changeset(
          %Task{},
          %{
            issue_id: issue.id,
            worktree_name: "schema-preload",
            worktree_path: "/tmp/schema-preload",
            scratch_path: "/tmp/schema-preload-scratch"
          },
          project.id
        )
      )

    preloaded = Repo.preload(task, [:project, issue: :owner_user])

    assert %Task{
             project: %Project{id: ^project_id},
             issue: %Issue{id: ^issue_id, owner_user: %User{id: ^user_id}}
           } = preloaded
  end

  test "preloads has_many questions, plans, runs, and designs", %{task: task, roles: roles} do
    %Task{id: task_id} = task = task

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    {:ok, _question} =
      Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{
        prompt: "Question prompt 12609?"
      })

    plan_scratch_45368 = Path.join("/tmp", "rail_plan_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plan_scratch_45368)
    on_exit(fn -> File.rm_rf(plan_scratch_45368) end)
    File.write!(Path.join(plan_scratch_45368, "plan.md"), "# Plan 13101")

    {:ok, _captured} = capture_scratch(:architect, %{task | scratch_path: plan_scratch_45368})

    {:ok, _plan} = Pipeline.get_plan(task)

    design_scratch_13102 = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir_13102 = Path.join(design_scratch_13102, "design")
    File.mkdir_p!(design_dir_13102)
    on_exit(fn -> File.rm_rf(design_scratch_13102) end)

    File.write!(Path.join(design_dir_13102, "dir-1.png"), "fake png content")

    File.write!(
      Path.join(design_dir_13102, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-13102",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })
    )

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, design_scratch_13102, url_probe: fn _url -> true end)

    preloaded = Repo.preload(task, [:questions, :plans, :runs, :designs])

    assert %Task{
             questions: [%Question{task_id: ^task_id}],
             plans: [%Plan{task_id: ^task_id}],
             runs: [%Run{task_id: ^task_id}],
             designs: [%Design{task_id: ^task_id}]
           } = preloaded
  end

  describe "uses_design?/1,2" do
    test "returns true when task is in :product or :design stage" do
      assert Task.uses_design?(%Task{stage: :product})
      assert Task.uses_design?(%Task{stage: :design})
    end

    test "returns true when runs list includes designer run" do
      task = %Task{id: "tsk_1", project_id: "prj_1", stage: :architect}

      assert Task.uses_design?(task, [%{role_id: "designer", task_id: "tsk_1"}])
      assert Task.uses_design?(task, [%{role: %{stage: :design}, task_id: "tsk_1"}])
      refute Task.uses_design?(task, [%{role_id: "engineer", task_id: "tsk_1"}])
    end

    test "checks database runs when task has advanced past design", %{project: project, task: task, roles: roles} do
      designer = roles[:design]

      {:ok, task_with_run} =
        Pipeline.update_task(task, %{
          stage: :architect
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_task_schema_12602",
        "identifier" => "TSK-12602",
        "title" => "Task 12602"
      })

      {:ok, issue_12602} = Issues.capture_issue(system_scope(), project, "Task 12602")

      {:ok, task_without_run} = Pipeline.create_task(issue_12602, :product)

      {:ok, task_without_run} =
        Pipeline.update_task(task_without_run, %{
          stage: :architect
        })

      {:ok, _run} =
        Runs.create_run(%{
          task_id: task_with_run.id,
          role_id: designer.id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      assert Task.uses_design?(task_with_run)
      refute Task.uses_design?(task_without_run)

      # runs with role_id matching DB designer role
      assert Task.uses_design?(task_with_run, [%{role_id: designer.id, task_id: task_with_run.id}])

      # run without designer role
      refute Task.uses_design?(task_with_run, [%{task_id: task_with_run.id, role_id: nil}])

      # project with no designer role in database
      {:ok, project_no_designer} =
        Projects.create_project(system_scope(), %{
          name: "Task Schema Project 12606",
          github_repo: "org/task-schema-12606",
          github_installation_id: 12_606,
          linear_team_id: "team_task_schema_12606",
          linear_team_key: "P12606",
          default_branch: "main",
          clone_path: "/tmp/repos/task-schema-12606",
          linear_state_ids: %{
            "triage" => "st_triage",
            "backlog" => "st_backlog",
            "in_progress" => "st_in_progress",
            "done" => "st_done",
            "canceled" => "st_canceled"
          }
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_task_schema_12603",
        "identifier" => "TSK-12603",
        "title" => "Task 12603"
      })

      {:ok, issue_12603} = Issues.capture_issue(system_scope(), project_no_designer, "Task 12603")

      {:ok, task_no_designer} = Pipeline.create_task(issue_12603, :product)

      {:ok, task_no_designer} =
        Pipeline.update_task(task_no_designer, %{
          stage: :architect
        })

      refute Task.uses_design?(task_no_designer)
    end

    test "returns false for invalid inputs" do
      refute Task.uses_design?(nil)
      refute Task.uses_design?(%{})
      refute Task.uses_design?(%Task{stage: :architect})
    end
  end

  describe "schema enums, accessors, and stage lifecycle helpers" do
    test "stages/0 and mergeabilities/0 return expected lists" do
      assert length(Task.stages()) == 11
      assert :product in Task.stages()
      assert :merged in Task.stages()

      # Off the linear path: a task can sit in it, but nothing advances into it.
      assert :debugger in Task.stages()
      assert Task.stage_index(:debugger) == nil
      assert Task.next_stage(:debugger) == nil
      refute Task.advanceable?(:debugger)

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
  end
end

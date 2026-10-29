defmodule Rail.Pipeline.Schemas.TaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_schema_1",
              "identifier" => "TSK-1",
              "title" => "Task Schema Issue"
            }
          }
        }
      })
    end)

    {:ok, %Issue{id: issue_id} = issue} =
      Issues.create_issue(system_scope(), project, %{description: "Task Schema Issue"})

    {:ok, %Task{id: task_id} = task} = Pipeline.create_task(issue, :plan)

    %{project: project, issue: issue, issue_id: issue_id, task: task, task_id: task_id, role: role}
  end

  test "an issue has at most one task", %{project: project, issue: issue, issue_id: issue_id, task_id: task_id} do
    attrs = %{issue_id: issue_id, worktree_name: "wt", worktree_path: "/tmp/wt", scratch_path: "/tmp/scratch"}

    assert {:error, changeset} = %Task{} |> Task.changeset(attrs, project.id) |> Repo.insert()
    assert %{issue_id: ["has already been taken"]} = errors_on(changeset)

    assert {:ok, %Task{id: ^task_id}} = Pipeline.create_task(issue, :plan)
  end

  test "changeset validates required fields" do
    assert %{project_id: ["can't be blank"], issue_id: ["can't be blank"]} = errors_on(Task.changeset(%Task{}, %{}))
    assert %{stage: ["can't be blank"]} = errors_on(Task.changeset(%Task{}, %{stage: nil}))
  end

  test "changeset accepts valid attributes and sets defaults", %{project: project, issue_id: issue_id} do
    attrs = %{
      issue_id: issue_id,
      worktree_name: "core-feature",
      worktree_path: "/tmp/repos/task-schema/.worktrees/core-feature",
      scratch_path: Path.join(System.tmp_dir!(), "rail_test_scratch_#{System.unique_integer([:positive])}")
    }

    changeset = Task.changeset(%Task{}, attrs, project.id)

    assert changeset.valid?
    assert get_field(changeset, :stage) == :plan
    assert get_field(changeset, :worktree_name) == "core-feature"
  end

  test "changeset validates enum types", %{project: project} do
    assert %{stage: ["is invalid"]} = errors_on(Task.changeset(%Task{}, %{stage: "invalid_stage"}, project.id))
  end

  test "ignores project_id passed in attrs to prevent unverified overrides", %{project: project} do
    attrs = %{
      project_id: "prj_untrusted",
      worktree_name: "wt",
      worktree_path: "/tmp/wt",
      scratch_path: "/tmp/scratch"
    }

    changeset = Task.changeset(%Task{}, attrs, project.id)

    assert get_field(changeset, :project_id) == project.id
  end

  test "validates foreign key on project_id", %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_task_schema_fk",
        identifier: "TSK-2",
        title: "Untasked Issue",
        state: :backlog
      })
      |> Repo.insert!()

    attrs = %{issue_id: issue.id, worktree_name: "wt", worktree_path: "/tmp/wt", scratch_path: "/tmp/scratch"}

    assert {:error, changeset} = %Task{} |> Task.changeset(attrs, "prj_missing") |> Repo.insert()
    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end

  test "preloads its project, issue, questions and runs", %{
    task: task,
    task_id: task_id,
    issue_id: issue_id,
    project: %{id: project_id},
    role: role
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%Question{task_id: run.task_id, run_id: run.id, prompt: "Question prompt 12609?"})

    assert %Task{
             project: %{id: ^project_id},
             issue: %{id: ^issue_id},
             questions: [%Question{task_id: ^task_id}],
             runs: [%Run{task_id: ^task_id}]
           } = Repo.preload(task, [:project, :issue, :questions, :runs])
  end

  test "running?/1 is true when any run on the task is executing", %{task: task, role: role} do
    refute Task.running?(%{task | runs: []})
    refute Task.running?(task)

    {:ok, idle} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    refute Task.running?(%{task | runs: [idle]})

    {:ok, busy} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert Task.running?(%{task | runs: [idle, busy]})
  end

  test "worktree_present?/1 answers for the directory, not the path", %{task: task} do
    refute Task.worktree_present?(task)

    # Not under the seeded project's clone path, which once on disk is where every later test's real git runs.
    task = %{task | worktree_path: Path.join(System.tmp_dir!(), "rail_wtp_#{System.unique_integer([:positive])}")}
    refute Task.worktree_present?(task)

    File.mkdir_p!(task.worktree_path)
    on_exit(fn -> File.rm_rf(task.worktree_path) end)

    assert Task.worktree_present?(task)
  end

  test "return_to_plan_changeset/1 puts the task at Plan and clears what belonged to its work" do
    now = DateTime.utc_now()

    task = %Task{
      stage: :finalize,
      pr_number: 212,
      pr_url: "https://github.com/org/repo/pull/212",
      pr_is_draft: false,
      worktree_slot: 7,
      worktree_setup_at: now,
      marked_ready_at: now,
      marked_ready_by_id: "usr_ready",
      base_behind: true,
      base_conflicts: ["lib/a.ex"],
      base_checked_at: now,
      merge_started_at: now,
      merge_error: "Refused",
      merge_error_at: now,
      merge_sha: "abc",
      worktree_name: "dsc-1-kept"
    }

    assert %Task{
             stage: :plan,
             pr_number: nil,
             pr_url: nil,
             pr_is_draft: nil,
             worktree_slot: nil,
             worktree_setup_at: nil,
             marked_ready_at: nil,
             marked_ready_by_id: nil,
             base_behind: false,
             base_conflicts: [],
             base_checked_at: nil,
             merge_started_at: nil,
             merge_error: nil,
             merge_error_at: nil,
             merge_sha: nil,
             worktree_name: "dsc-1-kept"
           } = task |> Task.return_to_plan_changeset() |> Ecto.Changeset.apply_changes()
  end

  test "stages/0 keeps every stage a row could have been written with" do
    assert :plan in Task.stages()
    refute :product in Task.stages()
    assert :merged in Task.stages()
    refute :debugger in Task.stages()
  end

  test "stage_label/1 names each stage" do
    assert Enum.map(Task.stages(), &Task.stage_label/1) == [
             "Plan",
             "Custom stage",
             "Implement",
             "Review",
             "Finalize",
             "Merged",
             "Split"
           ]

    assert is_nil(Task.stage_label(:nonsense))
  end

  # Review is one run of the Review lead, whose subagents are the review, QA, engineer and demo roles.
  test "role_stage/1 names the Review lead for Review and Finalize and every other stage's own role" do
    assert Enum.map(Task.stages(), &Task.role_stage/1) == [
             :plan,
             :custom,
             :engineer,
             :review_lead,
             :review_lead,
             :merged,
             :split
           ]
  end

  test "stage_run/1 is the latest run at the task's stage, or at Review a check since its lead that is not done", %{
    project: project,
    task: task,
    role: role
  } do
    now = DateTime.utc_now()
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)
    {:ok, demo} = Roles.get_role(project_id: project.id, stage: :demo)
    {:ok, reviewer} = Roles.get_role(project_id: project.id, stage: :review)

    {:ok, plan_run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: now})

    {:ok, last_round} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        started_at: DateTime.shift(now, hour: -2)
      })

    {:ok, retried} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        started_at: DateTime.shift(now, hour: -1)
      })

    {:ok, checking} = Pipeline.create_run(%{task_id: task.id, role_id: qa.id, status: :running, started_at: now})
    {:ok, recording} = Pipeline.create_run(%{task_id: task.id, role_id: demo.id, status: :running, started_at: now})
    # Reopened when its round started, and not retaken since.
    {:ok, earlier_review} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: reviewer.id,
        status: :finished,
        started_at: DateTime.shift(now, hour: -3)
      })

    {:ok, failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: reviewer.id,
        status: :finished,
        error: "No report.",
        started_at: now
      })

    runs = Repo.preload([plan_run, last_round, retried, recording, earlier_review], :role)
    [checking, failed] = Repo.preload([checking, failed], :role)

    assert Task.stage_run(%{task | runs: []}) == nil
    assert Task.stage_run(%{task | runs: runs}).id == plan_run.id
    # The demo recorder does not hold the review agent back, so it does not stand in for it.
    assert Task.stage_run(%{task | stage: :review, runs: runs}).id == retried.id
    assert Task.stage_run(%{task | stage: :review, runs: [checking | runs]}).id == checking.id
    assert Task.stage_run(%{task | stage: :review, runs: [failed | runs]}).id == failed.id
    assert Task.stage_run(%{task | stage: :review, runs: [failed, checking | runs]}).id == checking.id
    # A first round has no lead run yet for its checks to be newer than.
    assert Task.stage_run(%{task | stage: :review, runs: [failed]}).id == failed.id
    done = %{checking | status: :finished, stage_outcome: :done}
    assert Task.stage_run(%{task | stage: :review, runs: [done | runs]}).id == retried.id
    assert Task.stage_run(%{task | stage: :finalize, runs: [checking | runs]}).id == retried.id
  end

  test "demo_recorded?/1 is true once the demo recorder's video is on disk", %{task: task} do
    refute Task.demo_recorded?(task)

    File.mkdir_p!(Path.join(task.scratch_path, "demo"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    File.write!(Path.join([task.scratch_path, "demo", "demo.webm"]), "webm bytes")

    assert Task.demo_recorded?(task)
  end

  test "cast_stage/1 takes an atom or a string and refuses anything else" do
    assert Task.cast_stage(:plan) == {:ok, :plan}
    assert Task.cast_stage(:product) == :error
    assert Task.cast_stage("merged") == {:ok, :merged}
    assert Task.cast_stage(:nonsense) == :error
    assert Task.cast_stage("nonsense") == :error
    assert Task.cast_stage(123) == :error
  end

  test "a child builds only on the children before it", %{task: task} do
    assert %{valid?: true} = Task.changeset(task, %{split_position: 3, builds_on: [1, 2]})

    assert %{builds_on: ["must name only earlier children"]} =
             errors_on(Task.changeset(task, %{split_position: 2, builds_on: [2]}))

    assert %{builds_on: ["must name only earlier children"]} =
             errors_on(Task.changeset(task, %{split_position: 2, builds_on: [3]}))

    assert %{builds_on: ["must name only earlier children"]} =
             errors_on(Task.changeset(task, %{split_position: 2, builds_on: [0]}))

    assert %{split_position: ["must be greater than 0"]} = errors_on(Task.changeset(task, %{split_position: 0}))
  end

  test "finalize_state/1 reads unready, ready, merging, refused and merged off the task" do
    now = DateTime.utc_now()

    assert Task.finalize_state(%Task{stage: :finalize}) == :not_ready
    assert Task.finalize_state(%Task{stage: :finalize, marked_ready_at: now}) == :ready
    assert Task.finalize_state(%Task{stage: :finalize, marked_ready_at: now, merge_started_at: now}) == :merging
    assert Task.finalize_state(%Task{marked_ready_at: now, merge_started_at: now, merge_error: "Conflict"}) == :merging
    assert Task.finalize_state(%Task{stage: :finalize, marked_ready_at: now, merge_error: "Conflict"}) == :refused
    assert Task.finalize_state(%Task{stage: :merged, marked_ready_at: now, merged_at: now}) == :merged
  end

  # A merge whose caller died never answers, so after a minute it no longer holds the task.
  test "finalize_state/1 reads a merge started over a minute ago as abandoned" do
    stale = DateTime.shift(DateTime.utc_now(), second: -61)

    assert Task.finalize_state(%Task{marked_ready_at: stale, merge_started_at: stale}) == :ready
    assert Task.finalize_state(%Task{marked_ready_at: stale, merge_started_at: stale, merge_error: "No"}) == :refused
  end

  test "a task at a custom stage is worked by that stage's role and not by Engineer's, and names the stage" do
    engineer = %Role{stage: :engineer}
    license = %Role{custom_stage: "License check"}
    prompt = %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."}
    task = %Task{stage: :custom, custom_stage: "License check", issue: %Issue{stages: [prompt]}}

    assert Task.works_stage?(task, license)
    refute Task.works_stage?(task, engineer)
    refute Task.works_stage?(task, %Role{custom_stage: "Missing strings"})
    assert Task.works_stage?(%Task{stage: :engineer}, engineer)
    refute Task.works_stage?(%Task{stage: :engineer}, license)
    assert Task.works_stage?(%Task{stage: :review}, %Role{stage: :review_lead})

    assert Task.current_stage(task) == {:custom, "License check"}
    assert Task.current_stage(%Task{stage: :review}) == :review
    assert Task.custom_stage(task) == prompt
    assert Task.custom_stage(%Task{stage: :engineer}) == nil
    assert Task.stage_label(task) == "License check"
    assert Task.stage_label(%Task{stage: :engineer}) == "Implement"
    assert Task.stage_label({:custom, "License check"}) == "License check"
  end

  test "a custom stage needs its name, and any other stage drops the name of one it left", %{task: task} do
    assert %{custom_stage: ["can't be blank"]} = errors_on(Task.changeset(task, %{stage: :custom}))

    {:ok, licensed} = task |> Task.changeset(%{stage: :custom, custom_stage: "License check"}) |> Repo.update()

    assert {:ok, %Task{stage: :review, custom_stage: nil}} =
             licensed |> Task.changeset(%{stage: :review}) |> Repo.update()
  end
end

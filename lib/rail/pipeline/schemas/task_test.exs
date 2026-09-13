defmodule Rail.Pipeline.Schemas.TaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Schema Project 12601",
        github_repo: "org/task-schema-12601",
        github_installation_id: 12_601,
        linear_workspace: %{
          name: "Task Schema Workspace",
          external_id: "lin_ws_task_schema",
          token: "lin_api_token_task_schema",
          webhook_secret: "whsec_task_schema"
        },
        linear_team_key: "P12601",
        default_branch: "main",
        clone_path: "/tmp/repos/task-schema-12601",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

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

    {:ok, %Task{id: task_id} = task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, issue_id: issue_id, task: task, task_id: task_id, role: role}
  end

  test "an issue has at most one task", %{project: project, issue: issue, issue_id: issue_id, task_id: task_id} do
    attrs = %{issue_id: issue_id, worktree_name: "wt", worktree_path: "/tmp/wt", scratch_path: "/tmp/scratch"}

    assert {:error, changeset} = %Task{} |> Task.changeset(attrs, project.id) |> Repo.insert()
    assert %{issue_id: ["has already been taken"]} = errors_on(changeset)

    assert {:ok, %Task{id: ^task_id}} = Pipeline.create_task(issue, :product)
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
    assert get_field(changeset, :stage) == :product
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

    {:ok, _question} =
      Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{
        prompt: "Question prompt 12609?"
      })

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

    File.mkdir_p!(task.worktree_path)
    on_exit(fn -> File.rm_rf(task.worktree_path) end)

    assert Task.worktree_present?(task)
  end

  test "stages/0 keeps every stage a row could have been written with" do
    assert :product in Task.stages()
    assert :merged in Task.stages()
    assert :debugger in Task.stages()
  end

  test "stage_label/1 names each stage" do
    assert Enum.map(Task.stages(), &Task.stage_label/1) == [
             "Product",
             "Design",
             "Architect",
             "Engineer",
             "Review",
             "QA",
             "QA Lead",
             "Demo",
             "Ready to merge",
             "Merged",
             "Debugger"
           ]

    assert is_nil(Task.stage_label(:nonsense))
  end

  test "cast_stage/1 takes an atom or a string and refuses anything else" do
    assert Task.cast_stage(:product) == {:ok, :product}
    assert Task.cast_stage("merged") == {:ok, :merged}
    assert Task.cast_stage(:nonsense) == :error
    assert Task.cast_stage("nonsense") == :error
    assert Task.cast_stage(123) == :error
  end
end

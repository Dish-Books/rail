defmodule Rail.Pipeline.Actions.EnterStageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Enter Stage Project",
        github_repo: "org/enter-stage",
        github_installation_id: 44_001,
        linear_workspace: %{
          name: "Enter Stage Workspace",
          external_id: "lin_ws_enter_stage",
          token: "lin_api_token_enter_stage",
          webhook_secret: "whsec_enter_stage"
        },
        linear_team_key: "ENT",
        default_branch: "main",
        clone_path: "/tmp/repos/enter-stage",
        linear_state_ids: %{"triage" => "st_triage"}
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

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_enter_stage_1",
              "identifier" => "ENT-1",
              "title" => "Enter Stage Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Enter Stage Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, task: task, roles: roles}
  end

  setup %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    %{task: task}
  end

  test "writes the stage and starts the run that belongs to it", %{task: task, roles: roles} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    %{id: review_role_id} = roles[:review]

    assert {:ok, %Run{role_id: ^review_role_id, status: :running}} = Pipeline.enter_stage(task, :review)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "design is spawned with its own brief", %{task: task, roles: roles} do
    %{id: design_role_id} = roles[:design]

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "#{task.scratch_path}/design/manifest.json"
      {:ok, %OsProcess{run: spawned, task: task}}
    end)

    assert {:ok, %Run{role_id: ^design_role_id, status: :running}} = Pipeline.enter_stage(task, :design)
  end

  test "review is spawned with its own brief", %{task: task, roles: roles} do
    %{id: review_role_id} = roles[:review]

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "#{task.scratch_path}/reviews/ENT-1.json"
      {:ok, %OsProcess{run: spawned, task: task}}
    end)

    assert {:ok, %Run{role_id: ^review_role_id, status: :running}} = Pipeline.enter_stage(task, :review)
  end

  # QA has a role bound and no brief of its own, which is every stage Rail has
  # not built yet: the role's own instructions are the whole of what it gets.
  test "a stage with no brief of its own is spawned with the plain prompt", %{task: task, roles: roles} do
    %{id: qa_role_id} = roles[:qa]

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      refute prompt =~ task.scratch_path
      {:ok, %OsProcess{run: spawned, task: task}}
    end)

    assert {:ok, %Run{role_id: ^qa_role_id, status: :running}} = Pipeline.enter_stage(task, :qa)
  end

  test "unlatches a run that had already concluded, so the stage can conclude again", %{
    task: task,
    roles: roles
  } do
    {:ok, done} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        status: :finished,
        stage_outcome: :done,
        error: "Something went wrong last time.",
        started_at: DateTime.utc_now()
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.enter_stage(task, :review)
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(done)
  end

  test "a worktree Rail cannot make is recorded on the run, not swallowed", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/rail-no-such-worktree"})

    assert {:ok, %Run{status: :failed, error: error}} = Pipeline.enter_stage(task, :review)
    assert error =~ "Could not prepare the worktree"
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  # A run left running with no OS process behind it is one nothing recovers:
  # reconciliation works from `os_processes` rows and there is none, so it reads
  # as busy forever and hides every button that would move the task on.
  test "a spawn that never happens leaves the stage entered and the run settled", %{task: task} do
    stub(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:ok, %Run{status: :failed, error: "Dispatch is off, so no agent was started for this stage."}} =
             Pipeline.enter_stage(task, :review)

    assert %Task{stage: :review} = Repo.reload!(task)
    refute task |> Repo.preload(:runs, force: true) |> Task.running?()
  end

  test "a spawn that fails records the failure on the run", %{task: task} do
    stub(Tools, :start_os_process, fn spawned, _argv ->
      {:ok, failed} = spawned |> Run.changeset(%{error: "No such CLI binary"}) |> Repo.update()
      {:error, {:spawn_failed, :missing_binary, failed}}
    end)

    assert {:ok, %Run{error: "No such CLI binary"}} = Pipeline.enter_stage(task, :review)
  end
end

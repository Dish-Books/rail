defmodule Rail.Pipeline.Actions.SettleArchitectRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CaptureScratch

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Architect Workspace",
        external_id: "lin_ws_settle_architect",
        token: "lin_api_token_settle_architect",
        webhook_secret: "whsec_settle_architect"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Architect Project 14603",
        github_repo: "org/settle-architect-14603",
        github_installation_id: 14_603,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_architect_14603",
        linear_team_key: "P14603",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-architect-14603",
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
      "id" => "lin_settle_architect_1",
      "identifier" => "S14603-1",
      "title" => "Settle Architect Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Architect Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "settles clean exit 0 for architect stage advancing to awaiting_approval when plan exists", %{
    task: task,
    roles: roles
  } do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running
      })

    # settle_run captures the plan again, so keep the plan on the real filesystem.
    plan_dir = Path.join("/tmp", "rail_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plan_dir)
    File.write!(Path.join(plan_dir, "plan.md"), "# Architecture Plan")
    on_exit(fn -> File.rm_rf(plan_dir) end)

    {:ok, _captured} = capture_scratch(:architect, %{task | scratch_path: plan_dir})

    {:ok, _plan} = Pipeline.get_plan(system_scope(), task_id)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/settle_architect/#{role_run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval, retry_after: nil, error: nil},
            %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_architect_run(run)
  end

  test "settles clean exit 0 for architect stage failing when plan file was not written", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/settle_architect/#{role_run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: error_msg}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_architect_run(run)

    assert error_msg =~ "without writing a plan"
  end

  test "resolves string keys, updates associated Run, and captures scratch artifacts", %{
    task: task,
    roles: roles
  } do
    scratch_dir = create_temp_git_repo()

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running,
        scratch_path: scratch_dir
      })

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    %Run{id: run_id} =
      run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run_id,
        task_id: task_id,
        kind: :stage,
        stream_path: "/tmp/settle_architect/#{role_run_id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    plan_path = Path.join(scratch_dir, "plan.md")
    File.write!(plan_path, "# Captured Architecture Plan")

    outcome = %{
      "exit_code" => 0,
      "usage" => %{"input_tokens" => 500, "output_tokens" => 150},
      :run => run
    }

    {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, outcome)

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval}, %RoleRun{id: ^role_run_id, status: :finished}} =
             Pipeline.settle_architect_run(run)

    assert %Run{id: ^run_id, status: :finished} = Repo.get!(Run, run_id)
    assert %Plan{content: plan_content} = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert plan_content =~ "Captured Architecture Plan"
  end
end

defmodule Rail.Pipeline.Actions.SettleRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ProductRunFinished

  alias Rail.Domain.TaskUsage
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Run Workspace",
        external_id: "lin_ws_settle_run",
        token: "lin_api_token_settle_run",
        webhook_secret: "whsec_settle_run"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Run Project 14501",
        github_repo: "org/settle-run-14501",
        github_installation_id: 14_501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_run_14501",
        linear_team_key: "P14501",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-run-14501",
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
      "id" => "lin_settle_run_1",
      "identifier" => "STR-1",
      "title" => "Settle Run Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Run Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "settles clean exit 0 for product stage by parking at awaiting_approval", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    _product_role = roles[:product]

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :product,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_run/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{id: ^task_id, stage: :product, stage_state: :awaiting_approval},
            %Run{status: :finished, exit_code: 0, auto_retries: 0}} =
             finish_product_run(os_process)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}
  end

  test "settling the product stage writes nothing to Linear", %{task: task, issue: issue, roles: roles} do
    scratch_dir = Path.join(System.tmp_dir!(), "settle_product_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch_dir, "tickets"))
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    title_before = issue.title
    ticket_file = Path.join([scratch_dir, "tickets", "#{issue.identifier}.md"])
    File.write!(ticket_file, "---\ntitle: Rewritten by the product run\n---\n\nA body the human has not approved.\n")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :product,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:product].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    # No Linear mock is set up: a push would raise on the unexpected request.
    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_run/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{}, %Run{}} =
             finish_product_run(os_process)

    assert %Issue{title: ^title_before} = Repo.get!(Issue, issue.id)
  end

  test "an empty outcome keeps what the run layer already recorded", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(task, %{stage: :engineer, stage_state: :running})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: 1,
        error: "permanent boom"
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_run/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: "permanent boom"},
            %Run{status: :finished, exit_code: 1}} = Pipeline.settle_run(os_process)
  end

  test "resolves fallback exit code, string error, and prior run error", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: nil,
        error: nil
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_run/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert {:ok, _t1, %Run{exit_code: 0}} = Pipeline.settle_run(os_process, %{})

    assert {:ok, _t2, %Run{error: "string err"}} =
             Pipeline.settle_run(os_process, %{"error" => "string err", "exit_code" => 1})

    {:ok, run_err} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: 1,
        error: "prior err"
      })

    err_run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run_err.id,
        task_id: run_err.task_id,
        stream_path: "/tmp/settle_run/#{run_err.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert {:ok, _t3, %Run{error: "prior err"}} =
             Pipeline.settle_run(err_run, %{"exit_code" => 1})
  end

  test "resolves various usage input formats", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_run/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    usage_struct = %TaskUsage{input_tokens: 42, output_tokens: 10}

    assert {:ok, _t2, %Run{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(os_process, %{usage: usage_struct})

    assert {:ok, _t3, %Run{usage: %TaskUsage{input_tokens: 55}}} =
             Pipeline.settle_run(os_process, %{usage: %{"input_tokens" => 55}})

    assert {:ok, _t4, %Run{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(os_process, %{"usage" => usage_struct})
  end
end

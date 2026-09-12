defmodule Rail.Pipeline.Actions.SettleProductRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Domain.TaskUsage
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Settle Product Run Workspace",
        external_id: "lin_ws_settle_product_run",
        token: "lin_api_token_settle_product_run",
        webhook_secret: "whsec_settle_product_run"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Settle Product Run Project 14601",
        github_repo: "org/settle-product-run-14601",
        github_installation_id: 14_601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_product_run_14601",
        linear_team_key: "P14601",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-product-run-14601",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, product_role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_settle_product_run_1",
      "identifier" => "SPR-1",
      "title" => "Settle Product Run Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Product Run Issue")
    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, role: product_role}
  end

  defp running_task(task) do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{stage: :product, stage_state: :running})

    task
  end

  defp run(task, role, attrs \\ %{}) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            task_id: task.id,
            role_id: role.id,
            conversation_id: "sess_fixture",
            status: :running,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    run
  end

  defp os_process(run, status \\ :running) do
    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_product_run/#{run.id}.jsonl",
        node: to_string(Node.self()),
        status: status,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    os_process
  end

  test "returns invalid_state when the run's os process no longer exists", %{task: task, role: role} do
    run = run(running_task(task), role)
    os_process = os_process(run)

    Repo.delete!(run)

    assert {:error, :invalid_state} = Pipeline.settle_product_run(os_process)
  end

  test "parks a clean exit at awaiting_approval and broadcasts", %{task: task, role: role} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %Task{id: task_id} = task = running_task(task)
    os_process = task |> run(role, %{auto_retries: 2}) |> os_process()

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{id: ^task_id, stage: :product, stage_state: :awaiting_approval, error: nil, retry_after: nil},
            %Run{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_product_run(os_process)

    assert %OsProcess{status: :finished} = Repo.get!(OsProcess, os_process.id)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}
  end

  test "force-preloads the task, so a stale run handle still settles current state", %{task: task, role: role} do
    run = run(task, role)
    os_process = os_process(run)

    # The run was handed out before the task started; the settle must see :running, not the stale copy.
    running_task(task)

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_product_run(os_process)
  end

  test "writes nothing to Linear: the ticket stays in scratch until approval", %{
    task: task,
    issue: issue,
    role: role
  } do
    scratch_dir = Path.join(System.tmp_dir!(), "settle_product_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch_dir, "tickets"))
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    title_before = issue.title

    [scratch_dir, "tickets", "#{issue.identifier}.md"]
    |> Path.join()
    |> File.write!("---\ntitle: Rewritten by the product run\n---\n\nA body the human has not approved.\n")

    os_process = task |> running_task() |> run(role) |> os_process()

    # No Linear mock is set up: a push would raise on the unexpected request.
    assert {:ok, %Task{stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_product_run(os_process)

    assert %Issue{title: ^title_before} = Repo.get!(Issue, issue.id)
  end

  test "preserves an existing blocked question without parking for approval", %{task: task, role: role} do
    asking_run = run(task, role, %{status: :blocked_on_input})

    {:ok, %Question{id: expected_q_id}} =
      Pipeline.register_question(Repo.preload(asking_run, task: :issue), %DetectedQuestion{prompt: "Which scope?"})

    {:ok, _task} = Pipeline.update_task(system_scope(), task.id, %{stage: :product})

    os_process = os_process(asking_run)

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage_state: :blocked}, %Run{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_product_run(os_process)

    assert Enum.map(pending_questions(task.id), & &1.id) == [expected_q_id]
  end

  test "retries a transient failure with backoff while retries remain", %{task: task, role: role} do
    %Task{id: task_id} = task = running_task(task)
    os_process = task |> run(role, %{auto_retries: 0}) |> os_process()

    transient_err = "rate limit exceeded: 429 too many requests"

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 1, error: transient_err})

    assert {:ok, %Task{id: ^task_id, stage_state: :queued, retry_after: %DateTime{}, error: ^transient_err},
            %Run{status: :finished, auto_retries: 1, exit_code: 1}} =
             Pipeline.settle_product_run(os_process)
  end

  test "fails a transient failure once auto retries are exhausted", %{task: task, role: role} do
    os_process = task |> running_task() |> run(role, %{auto_retries: 2}) |> os_process()

    transient_err = "rate limit exceeded: 429 too many requests"

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 1, error: transient_err})

    assert {:ok, %Task{stage_state: :failed, retry_after: nil, error: ^transient_err},
            %Run{status: :finished, auto_retries: 2, exit_code: 1}} =
             Pipeline.settle_product_run(os_process)
  end

  test "fails a permanent failure immediately", %{task: task, role: role} do
    os_process = task |> running_task() |> run(role) |> os_process()

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 2})

    assert {:ok, %Task{stage_state: :failed, retry_after: nil, error: "Exited with code 2"},
            %Run{status: :finished, exit_code: 2}} =
             Pipeline.settle_product_run(os_process)
  end

  test "records usage from the outcome", %{task: task, role: role} do
    os_process = task |> running_task() |> run(role) |> os_process()
    usage = %TaskUsage{input_tokens: 11, output_tokens: 22}

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process, %{exit_code: 0, usage: usage})

    assert {:ok, %Task{stage_state: :awaiting_approval}, %Run{status: :finished, exit_code: 0}} =
             Pipeline.settle_product_run(os_process)

    assert %Run{usage: %TaskUsage{input_tokens: 11, output_tokens: 22}} =
             Repo.get!(Run, os_process.run_id)
  end

  test "falls back to the run's own exit code and error", %{task: task, role: role} do
    os_process =
      task
      |> running_task()
      |> run(role, %{exit_code: 1, error: "permanent boom"})
      |> os_process(:finished)

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(os_process)

    assert {:ok, %Task{stage_state: :failed, error: "permanent boom"}, %Run{status: :finished, exit_code: 1}} =
             Pipeline.settle_product_run(os_process)
  end
end

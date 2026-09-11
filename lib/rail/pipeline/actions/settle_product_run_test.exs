defmodule Rail.Pipeline.Actions.SettleProductRunTest do
  use Rail.DataCase, async: true

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
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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

  defp role_run(task, role, attrs \\ %{}) do
    {:ok, role_run} =
      Runs.create_role_run(
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

    role_run
  end

  defp run(role_run, status \\ :running) do
    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/settle_product_run/#{role_run.id}.jsonl",
        node: to_string(Node.self()),
        status: status,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    run
  end

  test "returns invalid_state when the run's role run no longer exists", %{task: task, role: role} do
    role_run = role_run(running_task(task), role)
    run = run(role_run)

    Repo.delete!(role_run)

    assert {:error, :invalid_state} = Pipeline.settle_product_run(run)
  end

  test "parks a clean exit at awaiting_approval and broadcasts", %{task: task, role: role} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %Task{id: task_id} = task = running_task(task)
    run = task |> role_run(role, %{auto_retries: 2}) |> run()

    assert {:ok, %Task{id: ^task_id, stage: :product, stage_state: :awaiting_approval, error: nil, retry_after: nil},
            %RoleRun{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_product_run(run, %{exit_code: 0})

    assert %Run{status: :finished} = Repo.get!(Run, run.id)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}
  end

  test "force-preloads the task, so a stale run handle still settles current state", %{task: task, role: role} do
    role_run = role_run(task, role)
    run = run(role_run)

    # The run was handed out before the task started; the settle must see :running, not the stale copy.
    running_task(task)

    assert {:ok, %Task{stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_product_run(run, %{exit_code: 0})
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

    run = task |> running_task() |> role_run(role) |> run()

    # No Linear mock is set up: a push would raise on the unexpected request.
    assert {:ok, %Task{stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_product_run(run, %{exit_code: 0}, scratch_dir: scratch_dir)

    assert %Issue{title: ^title_before} = Repo.get!(Issue, issue.id)
  end

  test "registers a detected question and leaves the task blocked", %{task: task, role: role} do
    run = task |> running_task() |> role_run(role) |> run()

    output = "Thinking...\n[QUESTION: Which persona is this for?] [OPTIONS: Admin, End user]"

    assert {:ok, %Task{stage: :product, stage_state: :blocked, question_id: "qst_" <> _rest},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_product_run(run, %{exit_code: 0, output: output})
  end

  test "preserves an existing blocked question without parking for approval", %{task: task, role: role} do
    {:ok, %Question{id: expected_q_id}} = Pipeline.register_question(task, %{prompt: "Which scope?"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :blocked,
        question_id: expected_q_id
      })

    run = task |> role_run(role, %{status: :blocked_on_input}) |> run()

    assert {:ok, %Task{stage_state: :blocked, question_id: ^expected_q_id},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_product_run(run, %{exit_code: 0, output: "Exiting after ask"})
  end

  test "retries a transient failure with backoff while retries remain", %{task: task, role: role} do
    %Task{id: task_id} = task = running_task(task)
    run = task |> role_run(role, %{auto_retries: 0}) |> run()

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok, %Task{id: ^task_id, stage_state: :queued, retry_after: %DateTime{}, error: ^transient_err},
            %RoleRun{status: :finished, auto_retries: 1, exit_code: 1}} =
             Pipeline.settle_product_run(run, %{exit_code: 1, error: transient_err})
  end

  test "fails a transient failure once auto retries are exhausted", %{task: task, role: role} do
    run = task |> running_task() |> role_run(role, %{auto_retries: 2}) |> run()

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok, %Task{stage_state: :failed, retry_after: nil, error: ^transient_err},
            %RoleRun{status: :finished, auto_retries: 2, exit_code: 1}} =
             Pipeline.settle_product_run(run, %{exit_code: 1, error: transient_err})
  end

  test "fails a permanent failure immediately", %{task: task, role: role} do
    run = task |> running_task() |> role_run(role) |> run()

    assert {:ok, %Task{stage_state: :failed, retry_after: nil, error: "Exited with code 2"},
            %RoleRun{status: :finished, exit_code: 2}} =
             Pipeline.settle_product_run(run, %{exit_code: 2})
  end

  test "records usage from the outcome", %{task: task, role: role} do
    run = task |> running_task() |> role_run(role) |> run()
    usage = %TaskUsage{input_tokens: 11, output_tokens: 22}

    assert {:ok, %Task{stage_state: :awaiting_approval}, %RoleRun{status: :finished, exit_code: 0, output: "done"}} =
             Pipeline.settle_product_run(run, %{exit_code: 0, output: "done", usage: usage})

    assert %RoleRun{usage: %TaskUsage{input_tokens: 11, output_tokens: 22}} =
             Repo.get!(RoleRun, run.role_run_id)
  end

  test "falls back to the role run's own exit code, error, and output", %{task: task, role: role} do
    run =
      task
      |> running_task()
      |> role_run(role, %{exit_code: 1, error: "permanent boom", output: "prior output"})
      |> run(:finished)

    assert {:ok, %Task{stage_state: :failed, error: "permanent boom"},
            %RoleRun{status: :finished, exit_code: 1, output: "prior output"}} =
             Pipeline.settle_product_run(run)
  end
end

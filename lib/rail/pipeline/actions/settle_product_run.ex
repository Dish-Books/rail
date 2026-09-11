defmodule Rail.Pipeline.Actions.SettleProductRun do
  @moduledoc """
  Settles a finished product-stage run.

  The run is the handle for everything: its role run and task are force-preloaded so
  the settle works from what is in the database now, not from whatever copy the caller
  was holding when the run started.

  The product agent's ticket stays in scratch until a human approves it: nothing is
  captured here, a clean exit only parks the task at `awaiting_approval`, and
  `approve_product_task/2` is what publishes the ticket and moves the pipeline on.

  A question the agent asked leaves the task blocked on it instead. A non-zero exit
  retries with backoff while the failure still looks transient, and fails the stage
  otherwise.
  """

  alias Rail.Domain.RunFailure
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc """
  Settles the finished product `run` against `outcome`:
  - Updates the `RoleRun` and `Run` records with exit code, output, error and usage.
  - Registers a detected question, leaving the task blocked on it.
  - Parks the task at `awaiting_approval` on exit 0.
  - Applies retry backoff or marks failure on non-zero exit.
  - Broadcasts `pipeline_changed`.
  """
  def settle_product_run(%Run{} = run, outcome \\ %{}, opts \\ []) do
    case Repo.preload(run, [role_run: :task], force: true) do
      %Run{role_run: %RoleRun{task: %Task{} = task} = role_run} = run ->
        do_settle_product_run(run, task, role_run, outcome, opts)

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  defp do_settle_product_run(%Run{} = run, %Task{} = task, %RoleRun{} = role_run, outcome, opts) do
    # An empty outcome means a re-settle: keep what the run layer already recorded.
    exit_code = Map.get(outcome, :exit_code) || role_run.exit_code || 0
    error = Map.get(outcome, :error) || role_run.error
    output = Map.get(outcome, :output) || role_run.output
    usage = Map.get(outcome, :usage)

    run |> Run.changeset(%{status: :finished}) |> Repo.update()

    {:ok, role_run} = update_role_run(role_run, exit_code, error, output, usage)
    {task, role_run} = maybe_register_question(task, role_run, outcome, output)

    {task_attrs, updated_role_run} = resolve_settle_outcome(task, role_run, exit_code, error)

    {:ok, updated_task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :run_settled})
    Pipeline.maybe_dispatch_queued_pending_chat(updated_task, opts)

    {:ok, updated_task, updated_role_run}
  end

  defp maybe_register_question(task, role_run, outcome, output) do
    detected_question =
      case Map.get(outcome, :detected_question) do
        %DetectedQuestion{} = question ->
          question

        _absent ->
          output && Runs.detect_question(output, task_id: task.id, role_id: role_run.role_id)
      end

    if detected_question && task.stage_state != :blocked && is_nil(task.question_id) do
      case Pipeline.register_question(task, role_run, detected_question) do
        {:ok, %Question{}} -> {Repo.get!(Task, task.id), Repo.get!(RoleRun, role_run.id)}
        _other -> {task, role_run}
      end
    else
      {task, role_run}
    end
  end

  # A task blocked on a question stays put: the answer, not this run, moves it on.
  defp resolve_settle_outcome(%Task{stage_state: :blocked, question_id: q_id}, role_run, _code, _error)
       when is_binary(q_id) do
    {%{}, role_run}
  end

  defp resolve_settle_outcome(_task, role_run, 0, _error) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{auto_retries: 0})
      |> Repo.update()

    attrs = %{
      stage_state: :awaiting_approval,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp resolve_settle_outcome(_task, role_run, exit_code, error) do
    error_msg = error || "Exited with code #{exit_code}"
    auto_retries = role_run.auto_retries || 0

    if RunFailure.transient?(error_msg) and auto_retries < RunFailure.max_auto_retries() do
      new_retries = auto_retries + 1
      delay_sec = RunFailure.retry_delay(new_retries) || 15
      retry_after = DateTime.shift(DateTime.utc_now(), second: delay_sec)

      {:ok, updated_role_run} =
        role_run
        |> RoleRun.changeset(%{auto_retries: new_retries})
        |> Repo.update()

      attrs = %{
        stage_state: :queued,
        retry_after: retry_after,
        error: error_msg
      }

      {attrs, updated_role_run}
    else
      attrs = %{
        stage_state: :failed,
        error: error_msg,
        retry_after: nil
      }

      {attrs, role_run}
    end
  end

  defp update_role_run(role_run, exit_code, error, output, usage) do
    new_status = if role_run.status == :blocked_on_input, do: :blocked_on_input, else: :finished

    attrs = %{
      status: new_status,
      completed_at: role_run.completed_at || DateTime.utc_now(),
      exit_code: exit_code,
      error: error,
      output: output
    }

    attrs = if usage, do: Map.put(attrs, :usage, usage), else: attrs

    role_run
    |> RoleRun.changeset(attrs)
    |> Repo.update()
  end
end

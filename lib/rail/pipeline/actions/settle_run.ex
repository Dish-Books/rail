# TODO: what is this doing, I want this combined into run_finished
defmodule Rail.Pipeline.Actions.SettleRun do
  @moduledoc """
  What settling a finished run means for every run, whatever stage it belongs to.

  The run layer calls this as a child exits, before it invokes the run's
  `on_finished` callback, so every run is recorded the same way whether or not
  anything is waiting on it.

  Two of the three outcomes are settled outright here:

  - a task parked on a question stays parked — the answer, not this settle, moves it on;
  - a non-zero exit retries with backoff while the failure still looks transient, and
    fails the stage otherwise.

  The third, a clean exit, is the stage's own business. This leaves the task alone
  and the stage's settle action — wired in as that run's `on_finished` — decides
  where it goes. Nothing here looks at `task.stage`.
  """

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Domain.RunFailure
  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Settles the finished `run` against `outcome`.

  The run is the handle for everything: its run and task are force-preloaded so
  the settle works from what is in the database now, not from whatever copy the caller
  was holding when the run started.
  """
  def settle_run(%OsProcess{} = os_process, outcome \\ %{}, opts \\ []) do
    case Repo.preload(os_process, [run: :task], force: true) do
      %OsProcess{run: %Run{task: %Task{} = task} = run} = os_process ->
        do_settle_run(os_process, task, run, outcome, opts)

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  defp do_settle_run(%OsProcess{} = os_process, %Task{} = task, %Run{} = run, outcome, opts) do
    # An empty outcome means a re-settle: keep what the run layer already recorded.
    exit_code = resolve_exit_code(outcome, run)
    error = resolve_error(outcome, run)
    usage = resolve_usage(outcome, run)

    os_process |> OsProcess.changeset(%{status: :finished}) |> Repo.update()

    {:ok, run} = update_run(run, exit_code, error, usage)

    case settle_outcome(task, exit_code, error, run) do
      :stage_decides ->
        {:ok, task, run}

      {task_attrs, run} ->
        finish(task, run, task_attrs, opts)
    end
  end

  # A task blocked on a question stays put: the answer, not this run, moves it on.
  defp settle_outcome(%Task{stage_state: :blocked, id: task_id}, _code, _error, run) do
    if pending_questions(task_id) == [], do: :stage_decides, else: {%{}, run}
  end

  defp settle_outcome(_task, 0, _error, _run), do: :stage_decides

  defp settle_outcome(_task, exit_code, error, run) do
    error_msg = error || "Exited with code #{exit_code}"
    auto_retries = run.auto_retries || 0

    if RunFailure.transient?(error_msg) and auto_retries < RunFailure.max_auto_retries() do
      new_retries = auto_retries + 1
      delay_sec = RunFailure.retry_delay(new_retries) || 15
      retry_after = DateTime.shift(DateTime.utc_now(), second: delay_sec)

      {:ok, updated_run} =
        run
        |> Run.changeset(%{auto_retries: new_retries})
        |> Repo.update()

      {%{stage_state: :queued, retry_after: retry_after, error: error_msg}, updated_run}
    else
      {%{stage_state: :failed, error: error_msg, retry_after: nil}, run}
    end
  end

  defp finish(task, run, task_attrs, opts) do
    {:ok, updated_task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :run_settled})
    Pipeline.maybe_dispatch_queued_pending_chat(updated_task, opts)

    {:ok, refreshed} = Pipeline.refresh_demo_freshness(updated_task, opts)

    {:ok, refreshed, run}
  end

  defp update_run(run, exit_code, error, usage) do
    new_status = if run.status == :blocked_on_input, do: :blocked_on_input, else: :finished

    attrs = %{
      status: new_status,
      completed_at: run.completed_at || DateTime.utc_now(),
      exit_code: exit_code,
      error: error
    }

    attrs = if usage, do: Map.put(attrs, :usage, usage), else: attrs

    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  defp resolve_exit_code(%{exit_code: code}, _run) when is_integer(code), do: code
  defp resolve_exit_code(%{"exit_code" => code}, _run) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, %Run{exit_code: code}) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, _run), do: 0

  defp resolve_error(%{error: err}, _run) when is_binary(err), do: err
  defp resolve_error(%{"error" => err}, _run) when is_binary(err), do: err
  defp resolve_error(_outcome, %Run{error: err}) when is_binary(err), do: err
  defp resolve_error(_outcome, _run), do: nil

  defp resolve_usage(%{usage: %TaskUsage{} = usage}, _run), do: Map.from_struct(usage)
  defp resolve_usage(%{usage: usage}, _run) when is_map(usage), do: usage
  defp resolve_usage(%{"usage" => %TaskUsage{} = usage}, _run), do: Map.from_struct(usage)
  defp resolve_usage(%{"usage" => usage}, _run) when is_map(usage), do: usage
  defp resolve_usage(_outcome, _run), do: nil
end

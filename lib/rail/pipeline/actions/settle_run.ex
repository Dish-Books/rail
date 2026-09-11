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

  alias Rail.Domain.RunFailure
  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc """
  Settles the finished `run` against `outcome`.

  The run is the handle for everything: its role run and task are force-preloaded so
  the settle works from what is in the database now, not from whatever copy the caller
  was holding when the run started.
  """
  def settle_run(%Run{} = run, outcome \\ %{}, opts \\ []) do
    case Repo.preload(run, [role_run: :task], force: true) do
      %Run{role_run: %RoleRun{task: %Task{} = task} = role_run} = run ->
        do_settle_run(run, task, role_run, outcome, opts)

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  defp do_settle_run(%Run{} = run, %Task{} = task, %RoleRun{} = role_run, outcome, opts) do
    # An empty outcome means a re-settle: keep what the run layer already recorded.
    exit_code = resolve_exit_code(outcome, role_run)
    error = resolve_error(outcome, role_run)
    usage = resolve_usage(outcome, role_run)

    run |> Run.changeset(%{status: :finished}) |> Repo.update()

    {:ok, role_run} = update_role_run(role_run, exit_code, error, usage)

    case settle_outcome(task, exit_code, error, role_run) do
      :stage_decides ->
        {:ok, task, role_run}

      {task_attrs, role_run} ->
        finish(task, role_run, task_attrs, opts)
    end
  end

  # A task blocked on a question stays put: the answer, not this run, moves it on.
  defp settle_outcome(%Task{stage_state: :blocked, question_id: q_id}, _code, _error, role_run) when is_binary(q_id) do
    {%{}, role_run}
  end

  defp settle_outcome(_task, 0, _error, _role_run), do: :stage_decides

  defp settle_outcome(_task, exit_code, error, role_run) do
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

      {%{stage_state: :queued, retry_after: retry_after, error: error_msg}, updated_role_run}
    else
      {%{stage_state: :failed, error: error_msg, retry_after: nil}, role_run}
    end
  end

  defp finish(task, role_run, task_attrs, opts) do
    {:ok, updated_task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :run_settled})
    Pipeline.maybe_dispatch_queued_pending_chat(updated_task, opts)

    {:ok, refreshed} = Pipeline.refresh_demo_freshness(updated_task, opts)

    {:ok, refreshed, role_run}
  end

  defp update_role_run(role_run, exit_code, error, usage) do
    new_status = if role_run.status == :blocked_on_input, do: :blocked_on_input, else: :finished

    attrs = %{
      status: new_status,
      completed_at: role_run.completed_at || DateTime.utc_now(),
      exit_code: exit_code,
      error: error
    }

    attrs = if usage, do: Map.put(attrs, :usage, usage), else: attrs

    role_run
    |> RoleRun.changeset(attrs)
    |> Repo.update()
  end

  defp resolve_exit_code(%{exit_code: code}, _role_run) when is_integer(code), do: code
  defp resolve_exit_code(%{"exit_code" => code}, _role_run) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, %RoleRun{exit_code: code}) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, _role_run), do: 0

  defp resolve_error(%{error: err}, _role_run) when is_binary(err), do: err
  defp resolve_error(%{"error" => err}, _role_run) when is_binary(err), do: err
  defp resolve_error(_outcome, %RoleRun{error: err}) when is_binary(err), do: err
  defp resolve_error(_outcome, _role_run), do: nil

  defp resolve_usage(%{usage: %TaskUsage{} = usage}, _role_run), do: Map.from_struct(usage)
  defp resolve_usage(%{usage: usage}, _role_run) when is_map(usage), do: usage
  defp resolve_usage(%{"usage" => %TaskUsage{} = usage}, _role_run), do: Map.from_struct(usage)
  defp resolve_usage(%{"usage" => usage}, _role_run) when is_map(usage), do: usage
  defp resolve_usage(_outcome, _role_run), do: nil
end

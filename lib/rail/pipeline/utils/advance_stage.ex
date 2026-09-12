defmodule Rail.Pipeline.Utils.AdvanceStage do
  @moduledoc """
  Moves a task on after its run settled clean.

  `Rail.Pipeline.Actions.SettleRun` has already run by the time a stage's settle
  action is called: the run and its os process are recorded, and a failure or a task
  parked on a question is already accounted for. So there is exactly one case
  left for a stage to decide, and this is the guard that hands it over.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Calls `fun` with the os process's task, run and `opts` when the os process
  exited cleanly, writes the task attributes it returns, and broadcasts.

  `fun` is `(task, run, opts)` returning `{task_attrs, run}`. When the os process
  failed, or the task is parked on a question, nothing is called and the task
  is left exactly as `settle_run` left it.
  """
  def advance_stage(%OsProcess{} = os_process, opts, fun) when is_function(fun, 3) do
    case Repo.preload(os_process, [run: :task], force: true) do
      %OsProcess{run: %Run{task: %Task{} = task} = run} ->
        if advancing?(task, run) do
          advance(task, run, opts, fun)
        else
          {:ok, task, run}
        end

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  # A task parked on a question stays parked: the answer, not this run, moves it on.
  defp advancing?(%Task{stage_state: :blocked, question_id: q_id}, _run) when is_binary(q_id), do: false
  defp advancing?(_task, %Run{exit_code: code}) when is_integer(code) and code != 0, do: false
  defp advancing?(_task, _run), do: true

  defp advance(task, run, opts, fun) do
    {task_attrs, run} = fun.(task, run, opts)

    {:ok, task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :run_settled})
    Pipeline.maybe_dispatch_queued_pending_chat(task, opts)

    {:ok, refreshed} = Pipeline.refresh_demo_freshness(task, opts)

    {:ok, refreshed, run}
  end
end

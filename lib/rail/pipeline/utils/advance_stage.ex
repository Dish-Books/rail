defmodule Rail.Pipeline.Utils.AdvanceStage do
  @moduledoc """
  Moves a task on after its run settled clean.

  `Rail.Pipeline.Actions.SettleRun` has already run by the time a stage's settle
  action is called: the run and role run are recorded, and a failure or a task
  parked on a question is already accounted for. So there is exactly one case
  left for a stage to decide, and this is the guard that hands it over.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc """
  Calls `fun` with the run's task, role run and `opts` when the run exited
  cleanly, writes the task attributes it returns, and broadcasts.

  `fun` is `(task, role_run, opts)` returning `{task_attrs, role_run}`. When the
  run failed, or the task is parked on a question, nothing is called and the task
  is left exactly as `settle_run` left it.
  """
  def advance_stage(%Run{} = run, opts, fun) when is_function(fun, 3) do
    case Repo.preload(run, [role_run: :task], force: true) do
      %Run{role_run: %RoleRun{task: %Task{} = task} = role_run} ->
        if advancing?(task, role_run) do
          advance(task, role_run, opts, fun)
        else
          {:ok, task, role_run}
        end

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  # A task parked on a question stays parked: the answer, not this run, moves it on.
  defp advancing?(%Task{stage_state: :blocked, question_id: q_id}, _role_run) when is_binary(q_id), do: false
  defp advancing?(_task, %RoleRun{exit_code: code}) when is_integer(code) and code != 0, do: false
  defp advancing?(_task, _role_run), do: true

  defp advance(task, role_run, opts, fun) do
    {task_attrs, role_run} = fun.(task, role_run, opts)

    {:ok, task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :run_settled})
    Pipeline.maybe_dispatch_queued_pending_chat(task, opts)

    {:ok, refreshed} = Pipeline.refresh_demo_freshness(task, opts)

    {:ok, refreshed, role_run}
  end
end

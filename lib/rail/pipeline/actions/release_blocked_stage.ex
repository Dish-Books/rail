defmodule Rail.Pipeline.Actions.ReleaseBlockedStage do
  @moduledoc """
  Action that releases a stage blocked on an agent question.
  Clears the question association, and either:
  - sets `:running` if a live process is running,
  - advances/settles the stage if finished with exit code 0,
  - marks `:failed` if finished with non-zero exit code, or
  - falls back to `:awaiting_approval` if no run exists.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.SettleAction

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Releases a blocked stage for a task with scope authorization.
  """
  def release_blocked_stage(%Scope{} = scope, task_or_id) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_release_blocked_stage(task)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def release_blocked_stage(task_or_id) do
    release_blocked_stage(Scope.for_system(), task_or_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_release_blocked_stage(%Task{} = task) do
    is_live = Runs.is_running?(task.id)

    latest_os_process =
      Repo.one(
        from r in OsProcess,
          where: r.task_id == ^task.id,
          order_by: [desc: r.inserted_at],
          limit: 1
      )

    latest_run =
      Repo.one(
        from rr in Run,
          where: rr.task_id == ^task.id,
          order_by: [desc: rr.inserted_at],
          limit: 1
      )

    cond do
      is_live ->
        release_to_running(task)

      has_finished_run?(latest_os_process, latest_run) ->
        release_finished_run(task, latest_os_process, latest_run)

      true ->
        release_to_awaiting_approval(task)
    end
  end

  defp release_to_running(%Task{} = task) do
    {:ok, updated_task} =
      task
      |> Task.changeset(%{question_id: nil, stage_state: :running})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_released})
    {:ok, updated_task}
  end

  # Settling goes through the run, so a run with no run row left to settle
  # falls through to the awaiting-approval branch instead.
  defp has_finished_run?(%OsProcess{} = latest_os_process, latest_run) do
    latest_os_process.status == :finished || (latest_run && latest_run.exit_code != nil)
  end

  defp has_finished_run?(_no_run, _latest_run), do: false

  defp release_finished_run(%Task{} = task, %OsProcess{} = latest_os_process, latest_run) do
    exit_code =
      if latest_run && is_integer(latest_run.exit_code) do
        latest_run.exit_code
      else
        0
      end

    if exit_code == 0 do
      {:ok, cleared_task} =
        task
        |> Task.changeset(%{question_id: nil})
        |> Repo.update()

      settle = settle_action(cleared_task)

      with {:ok, _settled_task, _run} <- Pipeline.settle_run(latest_os_process, %{exit_code: 0}),
           {:ok, advanced_task, _run} <- settle.(latest_os_process, %{}, []) do
        {:ok, advanced_task}
      end
    else
      {:ok, updated_task} =
        task
        |> Task.changeset(%{question_id: nil, stage_state: :failed})
        |> Repo.update()

      Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_released})
      {:ok, updated_task}
    end
  end

  defp release_to_awaiting_approval(%Task{} = task) do
    {:ok, updated_task} =
      task
      |> Task.changeset(%{question_id: nil, stage_state: :awaiting_approval})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_released})
    {:ok, updated_task}
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end

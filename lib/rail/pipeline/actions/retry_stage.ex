defmodule Rail.Pipeline.Actions.RetryStage do
  @moduledoc """
  Action to manually retry a failed or backoff-waiting stage run.
  Resets auto-retries, clears retry backoff timers and errors, re-queues the stage,
  and triggers a dispatcher queue pump.
  """

  import Ecto.Query

  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @doc """
  Retries the current stage of a task:
  - Resolves role for the current stage (or engineer if rebasing).
  - Clears `retry_after` and `error`.
  - Sets `stage_state: :queued`.
  - Resets `auto_retries = 0` on the corresponding `RoleRun`.
  - Broadcasts `pipeline_changed` and pumps the Dispatcher.
  """
  def retry_stage(%Scope{} = scope, task_or_id) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_retry_stage(task)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def retry_stage(task_or_id) do
    retry_stage(Scope.for_system(), task_or_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_retry_stage(%Task{} = task) do
    stage_to_find = if task.is_rebasing, do: :engineer, else: task.stage

    case Roles.role_for_stage(task.project_id, stage_to_find) do
      {:ok, %Role{} = role} ->
        execute_retry(task, role)

      _no_role ->
        {:error, {:no_role_for_stage, stage_to_find}}
    end
  end

  defp execute_retry(%Task{} = task, %Role{} = role) do
    reset_role_run_retries(task.id, role.id)

    attrs = %{
      stage_state: :queued,
      retry_after: nil,
      error: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_retried})
    Dispatcher.pump()

    {:ok, updated_task}
  end

  defp reset_role_run_retries(task_id, role_id) do
    case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %RoleRun{} = existing ->
        existing
        |> RoleRun.changeset(%{auto_retries: 0})
        |> Repo.update!()

      nil ->
        :ok
    end
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end

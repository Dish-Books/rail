defmodule Rail.Pipeline.Actions.CancelPendingChat do
  @moduledoc """
  Cancels an undelivered queued chat turn held on a role run.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @doc """
  Cancels any queued pending_chat message for the role on the given task.
  """
  def cancel_pending_chat(%Scope{} = scope, task_or_id, role_id) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id),
         %RoleRun{} = role_run <- resolve_role_run(task.id, role_id) do
      do_cancel_pending_chat(task, role_run)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def cancel_pending_chat(task_or_id, role_id) do
    cancel_pending_chat(Scope.for_system(), task_or_id, role_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp resolve_task(%Task{} = task), do: Repo.get(Task, task.id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

  defp resolve_role_run(task_id, role_id) do
    Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id)
  end

  defp do_cancel_pending_chat(task, %RoleRun{pending_chat: nil} = role_run) do
    {:ok, role_run, task}
  end

  defp do_cancel_pending_chat(task, %RoleRun{} = role_run) do
    Runs.append_run_event(role_run.id, "[rail] Queued message cancelled by user.")

    {:ok, updated_role_run} =
      role_run
      |> RoleRun.changeset(%{pending_chat: nil})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :pending_chat_cancelled})

    {:ok, updated_role_run, task}
  end
end

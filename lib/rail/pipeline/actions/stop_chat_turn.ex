defmodule Rail.Pipeline.Actions.StopChatTurn do
  @moduledoc """
  Stops an active interactive chat turn on a task, killing the runner process,
  clearing the active chat role, and appending a stop notice to the transcript.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @doc """
  Stops the currently running chat turn for the given task.
  """
  def stop_chat_turn(%Scope{} = scope, task_or_id) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_stop_chat_turn(task)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def stop_chat_turn(task_or_id) do
    stop_chat_turn(Scope.for_system(), task_or_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp resolve_task(%Task{} = task), do: Repo.get(Task, task.id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

  defp do_stop_chat_turn(%Task{active_chat_role_id: nil} = task) do
    {:ok, task}
  end

  defp do_stop_chat_turn(%Task{active_chat_role_id: role_id} = task) do
    Runs.stop_run(task.id)

    case Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^role_id) do
      %RoleRun{} = role_run ->
        role_run
        |> RoleRun.changeset(%{
          pending_chat: nil,
          chat_fingerprint_head_sha: nil,
          chat_fingerprint_dirty_digest: nil
        })
        |> Repo.update!()

        Runs.append_run_event(role_run.id, "[axis] Chat turn stopped by user.")

      nil ->
        :ok
    end

    {:ok, updated_task} =
      task
      |> Task.changeset(%{active_chat_role_id: nil})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :chat_stopped})

    {:ok, updated_task}
  end
end

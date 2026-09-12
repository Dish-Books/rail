defmodule Rail.Pipeline.Actions.CancelPendingChat do
  @moduledoc """
  Cancels an undelivered queued chat turn held on a run.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @doc """
  Cancels any queued pending_chat message for the role on the given task.
  """
  # TODO: this should take a run struct
  def cancel_pending_chat(%Task{} = task, role_id) do
    case resolve_run(task.id, role_id) do
      %Run{} = run -> do_cancel_pending_chat(task, run)
      nil -> {:error, :not_found}
    end
  end

  defp resolve_run(task_id, role_id) do
    Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id)
  end

  defp do_cancel_pending_chat(task, %Run{pending_chat: nil} = run) do
    {:ok, run, task}
  end

  defp do_cancel_pending_chat(task, %Run{} = run) do
    Runs.append_run_event(run.id, "[rail] Queued message cancelled by user.")

    {:ok, updated_run} =
      run
      |> Run.changeset(%{pending_chat: nil})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :pending_chat_cancelled})

    {:ok, updated_run, task}
  end
end

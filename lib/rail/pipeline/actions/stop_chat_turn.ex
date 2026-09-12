defmodule Rail.Pipeline.Actions.StopChatTurn do
  @moduledoc """
  Stops an active interactive chat turn on a task, killing the runner process,
  clearing the active chat role, and appending a stop notice to the transcript.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Stops the currently running chat turn for the given task.
  """
  def stop_chat_turn(%Task{} = task) do
    do_stop_chat_turn(task)
  end

  defp do_stop_chat_turn(%Task{active_chat_role_id: nil} = task) do
    {:ok, task}
  end

  defp do_stop_chat_turn(%Task{active_chat_role_id: role_id} = task) do
    case Runs.get_active_os_process(task.id) do
      %OsProcess{} = os_process -> Runs.stop_os_process(os_process)
      nil -> :ok
    end

    case Repo.one(from r in Run, where: r.task_id == ^task.id and r.role_id == ^role_id) do
      %Run{} = run ->
        run
        |> Run.changeset(%{
          pending_chat: nil,
          chat_fingerprint_head_sha: nil,
          chat_fingerprint_dirty_digest: nil
        })
        |> Repo.update!()

        Runs.append_run_event(run.id, "[rail] Chat turn stopped by user.")

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

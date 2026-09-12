defmodule Rail.Pipeline.Actions.CancelTask do
  @moduledoc """
  Action to cancel an active or running task run.
  Stops any running follower process, terminates active chat, and updates the task
  status:
  - When rebasing: returns the task to its pre-rebase stage with a rebase cancelled message.
  - When not rebasing: sets stage_state to `:failed` with `"Cancelled."` error.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess

  @doc """
  Cancels a task run.
  """
  # TODO: this should take a run struct
  def cancel_task(%Task{} = task, _opts \\ []) do
    if is_binary(task.active_chat_role_id) and task.active_chat_role_id != "" do
      Rail.Pipeline.stop_chat_turn(task)
    end

    case Runs.get_active_os_process(task.id) do
      %OsProcess{} = os_process -> Runs.stop_os_process(os_process)
      nil -> :ok
    end

    attrs =
      if task.is_rebasing do
        %{
          is_rebasing: false,
          stage_state: task.stage_state_before_rebase || :awaiting_approval,
          stage_state_before_rebase: nil,
          error: "Rebase cancelled. The branch still conflicts.",
          retry_after: nil,
          active_chat_role_id: nil
        }
      else
        %{
          stage_state: :failed,
          error: "Cancelled.",
          retry_after: nil,
          active_chat_role_id: nil
        }
      end

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :task_cancelled
    })

    {:ok, updated_task}
  end
end

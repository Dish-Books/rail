defmodule Rail.Pipeline.Actions.StartRebase do
  @moduledoc """
  Action to initiate an engineer rebase run for a conflicted task.
  Preserves the existing pipeline stage while dispatching the engineer role
  to rebase the task branch against the project's default branch.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Starts a rebase pass on a task.
  """

  def start_rebase(%Task{} = task, opts \\ []) do
    if Task.busy?(task) do
      {:error, :task_busy}
    else
      execute_rebase_start(task, opts)
    end
  end

  defp execute_rebase_start(%Task{} = task, _opts) do
    attrs = %{
      is_rebasing: true,
      stage_state_before_rebase: task.stage_state,
      stage_state: :queued,
      error: nil,
      retry_after: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :rebase_started
    })

    {:ok, updated_task}
  end
end

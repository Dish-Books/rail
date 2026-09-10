defmodule Rail.Pipeline.Actions.CancelTask do
  @moduledoc """
  Action to cancel an active or running task run.
  Cancels retry timers, stops any running follower process, terminates active chat,
  and updates the task status:
  - When rebasing: returns the task to its pre-rebase stage with a rebase cancelled message.
  - When not rebasing: sets stage_state to `:failed` with `"Cancelled."` error.
  """

  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Scope

  @doc """
  Cancels a task run.
  """
  def cancel_task(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_cancel_task(task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def cancel_task(task_or_id, opts) when is_list(opts) do
    cancel_task(Scope.for_system(), task_or_id, opts)
  end

  def cancel_task(scope, task_or_id) do
    cancel_task(scope, task_or_id, [])
  end

  def cancel_task(task_or_id) do
    cancel_task(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_cancel_task(%Task{} = task, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, Dispatcher)

    if GenServer.whereis(dispatcher) do
      Dispatcher.cancel_retry_timer(dispatcher, task.id)
    end

    if is_binary(task.active_chat_role_id) and task.active_chat_role_id != "" do
      Rail.Pipeline.stop_chat_turn(task.id)
    end

    Runs.stop_run(task.id)

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

  defp resolve_task(%Task{} = task), do: Repo.get(Task, task.id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end

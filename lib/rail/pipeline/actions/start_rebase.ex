defmodule Rail.Pipeline.Actions.StartRebase do
  @moduledoc """
  Action to initiate an engineer rebase run for a conflicted task.
  Preserves the existing pipeline stage while dispatching the engineer role
  to rebase the task branch against the project's default branch.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Starts a rebase pass on a task.
  """
  def start_rebase(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_start_rebase(task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def start_rebase(task_or_id, opts) when is_list(opts) do
    start_rebase(Scope.for_system(), task_or_id, opts)
  end

  def start_rebase(scope, task_or_id) do
    start_rebase(scope, task_or_id, [])
  end

  def start_rebase(task_or_id) do
    start_rebase(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(nil), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_start_rebase(%Task{} = task, opts) do
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

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end

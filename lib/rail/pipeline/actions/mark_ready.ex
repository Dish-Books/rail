defmodule Rail.Pipeline.Actions.MarkReady do
  @moduledoc """
  A teammate marks a task at Finalize ready for a tech lead, which puts it in the review queue. The mark is
  taken with a conditional update, so a second one from another tab keeps the first. There is no unmark.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Marks `task` ready as the scope's user. Returns `{:ok, task}` as it now stands, or `{:error, reason}` for a
  project the scope cannot open, a task not at Finalize, or one with no pull request.
  """
  def mark_ready(%Scope{} = scope, %Task{} = task) do
    task = Repo.get!(Task, task.id)

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- markable(task) do
      {_marked, _rows} =
        Repo.update_all(
          from(t in Task,
            where:
              t.id == ^task.id and t.project_id == ^task.project_id and t.stage == :finalize and
                is_nil(t.marked_ready_at)
          ),
          set: [marked_ready_at: DateTime.utc_now(), marked_ready_by_id: scope.user && scope.user.id]
        )

      marked = task |> Repo.reload!() |> Repo.preload(:marked_ready_by) |> broadcast_pipeline_changed()
      {:ok, marked}
    end
  end

  defp markable(%Task{stage: stage}) when stage != :finalize, do: {:error, {:invalid_stage, stage}}
  defp markable(%Task{pr_number: nil}), do: {:error, :no_pull_request}
  defp markable(%Task{}), do: :ok
end

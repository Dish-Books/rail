defmodule Rail.Pipeline.Actions.MarkReady do
  @moduledoc """
  A teammate marks a task at Finalize ready for a tech lead, which puts it in the review queue and queues a curator
  pass on it. The mark is taken with a conditional update, so a second one from another tab keeps the first and
  queues nothing. There is no unmark.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartCurator
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Marks `task` ready as the scope's user. Returns `{:ok, task}` as it now stands, or `{:error, reason}` for a
  project the scope cannot open, a user without GitHub, a task not at Finalize, one with no pull request, one an
  agent other than the curator works on (`:stage_running`), or one whose fix plan waits on approval.
  """
  def mark_ready(%Scope{} = scope, %Task{} = task) do
    # Overview offers the mark on a row a deletion may have taken since it was drawn.
    with %Task{} = task <- Repo.get(Task, task.id) || {:error, :not_found},
         true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         task = Repo.preload(task, [:issue, runs: :role]),
         :ok <- github_linked(scope),
         :ok <- markable(task),
         :ok <- settled(task) do
      {:ok, _marked} =
        Repo.transaction(fn ->
          {marked, _rows} =
            Repo.update_all(
              from(t in Task,
                where:
                  t.id == ^task.id and t.project_id == ^task.project_id and t.stage == :finalize and
                    is_nil(t.marked_ready_at)
              ),
              set: [marked_ready_at: DateTime.utc_now(), marked_ready_by_id: scope.user && scope.user.id]
            )

          # Each time the task goes to the tech leads, the curator reads it again.
          if marked == 1, do: {:ok, _job} = %{task_id: task.id} |> StartCurator.new() |> Oban.insert()
          marked
        end)

      marked = task |> Repo.reload!() |> Repo.preload(:marked_ready_by) |> broadcast_pipeline_changed()
      {:ok, marked}
    end
  end

  # Read again, since a page's scope can be from before they disconnected GitHub.
  defp github_linked(%Scope{user: %{id: user_id}}) do
    case Repo.get(User, user_id) do
      %User{github_id: github_id} when is_binary(github_id) -> :ok
      _unlinked_or_gone -> {:error, :github_not_linked}
    end
  end

  defp github_linked(%Scope{system: true}), do: :ok

  defp markable(%Task{stage: stage}) when stage != :finalize, do: {:error, {:invalid_stage, stage}}
  defp markable(%Task{pr_number: nil}), do: {:error, :no_pull_request}
  defp markable(%Task{}), do: :ok

  # A page may still offer the mark after a comment resumed the review agent or its fix plan was saved.
  defp settled(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      match?(%FixPlan{approved_at: nil}, Pipeline.read_fix_plan(task)) -> {:error, :fix_plan_waiting}
      true -> :ok
    end
  end
end

defmodule Rail.Pipeline.Actions.UpdateBranch do
  @moduledoc """
  Update on a task whose branch is behind the default branch: a round of its own, whose plan is to merge the
  default branch in and resolve what conflicts. Bringing a branch up to date is no change to what the ticket asks,
  so the person who clicked approves it, and the engineer starts at once on a clean conversation. Its push goes
  through the round's checks like any other, and a task marked ready is not ready any more, since its branch moves.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Starts the round that brings `task`'s branch up to date, as the scope's user. Returns `{:ok, round}`, or
  `{:error, reason}`: `:not_found`, `{:invalid_stage, stage}` before Review or once merged, `:stage_running` while
  anything works on the task, or `:up_to_date` when the branch already holds the default branch.
  """
  def update_branch(%Scope{} = scope, %Task{} = task) do
    result =
      Repo.transaction(fn ->
        # Of two clicks the second waits here, then finds the task back at Engineer.
        task = Repo.one!(from t in Task, where: t.id == ^task.id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:project, :runs])

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             :ok <- updatable(task),
             {:ok, task} <- Pipeline.check_base(task),
             true <- task.base_behind || {:error, :up_to_date} do
          start(scope, task)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {%Task{} = task, %Round{} = round}} <- result do
      broadcast_pipeline_changed(task)
      {:ok, round}
    end
  end

  defp updatable(%Task{stage: stage}) when stage not in [:review, :finalize], do: {:error, {:invalid_stage, stage}}
  defp updatable(%Task{} = task), do: if(Task.running?(task), do: {:error, :stage_running}, else: :ok)

  # The round, the move and the job commit together, so an Update always has an engineer to start.
  defp start(%Scope{user: user}, %Task{project: %Project{default_branch: base}} = task) do
    {:ok, round} = Pipeline.create_round(task)

    {:ok, round} =
      round
      |> Round.approve_changeset(user && user.id)
      |> Ecto.Changeset.change(
        plan: plan(base, task.base_conflicts),
        plan_saved_at: DateTime.utc_now(),
        base_head: Git.branch_fingerprint(task.worktree_path)[:head_sha]
      )
      |> Repo.update()

    {:ok, task} = task |> Task.changeset(%{marked_ready_at: nil, marked_ready_by_id: nil}) |> Repo.update()
    {:ok, task} = Pipeline.enter_stage(task, :engineer, start: false)
    {:ok, _job} = Oban.insert(StartEngineer.new(%{task_id: task.id}))
    {task, round}
  end

  defp plan(base, conflicts) do
    where =
      case conflicts do
        [] -> "It merges cleanly as Rail last checked, but check every file the merge touches."
        paths -> "It conflicts in " <> Enum.map_join(paths, ", ", &"`#{&1}`") <> "."
      end

    """
    ### What changes

    Bring the branch up to date with `origin/#{base}` by merging it in. #{where} Resolve each conflict the way both sides meant it: keep what the default branch changed and everything the earlier rounds built. Nothing else changes this round.

    ### Verification

    Run the project's checks once the merge is committed, and fix what the merge broke.
    """
  end
end

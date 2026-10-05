defmodule Rail.Pipeline.Actions.EndTurnAndMerge do
  @moduledoc """
  The engineer's `request_merge`: ends the turn, since `update_branch/2` refuses a
  busy task, then merges the default branch in as the Update branch button does.
  """

  import Rail.Pipeline.Utils.EndEngineerTurn
  import Rail.Pipeline.Utils.WithLiveTurn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Ends `task`'s engineer turn, carried by `os_process`, and merges the default
  branch in: `{:ok, :merging}`, `{:refused, text}` with the turn still going or
  already ended, or `{:error, reason}` from the fetch.
  """
  def end_turn_and_merge(%Task{} = task, %OsProcess{} = os_process) do
    case with_live_turn(os_process, fn -> task |> Repo.reload!() |> Repo.preload(:project) |> accept() end) do
      :ended -> {:refused, "Refused, nothing merged again. This turn has already ended and handed the merge to Rail."}
      result -> result
    end
  end

  defp accept(%Task{project: %Project{} = project} = task) do
    base = project.default_branch

    cond do
      task.stage != :engineer ->
        {:refused,
         "Refused, nothing merged. The task is at #{Task.stage_label(task.stage)}, not Engineer, so its branch is not " <>
           "updated from here."}

      task.is_updating_branch or Git.merge_in_progress?(task.worktree_path) ->
        {:refused, "Refused, nothing merged. A merge is already under way on this branch."}

      Git.worktree_dirty?(task.worktree_path) ->
        {:refused,
         "Refused, nothing merged. The worktree has uncommitted changes. Call commit to hand them over; " <>
           "request_merge is for a clean worktree."}

      true ->
        with :ok <- Git.fetch_default_branch(project, task.worktree_path),
             false <- Git.up_to_date_with?(task.worktree_path, base) do
          :ok = end_engineer_turn(task, fn -> merge(task) end)
          {:ok, :merging}
        else
          true -> {:refused, "Refused, nothing merged. This branch already has everything on origin/#{base}."}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp merge(%Task{} = task) do
    case Pipeline.update_branch(Scope.for_system(), task) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, "Could not merge the default branch in: #{describe(reason)}"}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end

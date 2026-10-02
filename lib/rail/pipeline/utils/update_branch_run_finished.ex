defmodule Rail.Pipeline.Utils.UpdateBranchRunFinished do
  @moduledoc """
  Where an engineer turn spent resolving merge conflicts leaves its run.

  Rail commits the merge from what the engineer staged. Conflicts it left
  unresolved, or a merge it abandoned, keep the task updating for the message
  that finishes the job.
  """

  import Rail.Pipeline.Utils.UpdateBranchPass

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` after a turn it was asked to resolve conflicts in."
  def update_branch_run_finished(%Run{task: %Task{worktree_path: worktree_path} = task} = run) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)

    cond do
      Git.conflicted_files(worktree_path) != [] ->
        fail(run, "The engineer stopped with conflicts still unresolved. Message it to finish them.")

      not Git.merge_in_progress?(worktree_path) and not Git.up_to_date_with?(worktree_path, base) ->
        fail(run, "The merge of origin/#{base} was abandoned before it finished. Update the branch again when ready.")

      true ->
        carry_on(run)
    end
  end

  defp carry_on(%Run{} = run) do
    case update_branch_pass(Scope.for_system(), run) do
      {:ok, %Run{} = carried} -> carried
      {:error, reason} -> fail(run, "The merge could not be finished: #{describe(reason)}")
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end

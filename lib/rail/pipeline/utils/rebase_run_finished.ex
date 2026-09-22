defmodule Rail.Pipeline.Utils.RebaseRunFinished do
  @moduledoc """
  Where an engineer turn spent resolving rebase conflicts leaves its run.

  Rail carries the rebase on from what the engineer staged. Conflicts it left
  unresolved, or a rebase it abandoned, keep the task rebasing for the message
  that finishes the job; the next commit conflicting sends the engineer back.
  """

  import Rail.Pipeline.Utils.RebasePass

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` after a turn it was asked to resolve conflicts in."
  def rebase_run_finished(%Run{task: %Task{worktree_path: worktree_path} = task} = run) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)

    cond do
      Git.conflicted_files(worktree_path) != [] ->
        fail(run, "The engineer stopped with conflicts still unresolved. Message it to finish them.")

      not Git.rebase_in_progress?(worktree_path) and not Git.rebased_onto?(worktree_path, base) ->
        fail(run, "The rebase onto origin/#{base} was abandoned before it finished. Rebase again when ready.")

      true ->
        carry_on(run)
    end
  end

  defp carry_on(%Run{} = run) do
    case rebase_pass(Scope.for_system(), run) do
      {:ok, %Run{} = carried} -> carried
      {:error, reason} -> fail(run, "The rebase could not be finished: #{describe(reason)}")
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end

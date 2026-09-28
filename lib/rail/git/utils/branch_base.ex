defmodule Rail.Git.Utils.BranchBase do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  The commit `task`'s branch is diffed from: where it forked from its base, or
  `HEAD` when it shares no history with it yet.

  The merge base rather than the base branch's tip keeps the base moving ahead
  out of the picture. It is `origin/`'s, the one rebases land on.
  """
  def branch_base(%Task{worktree_path: worktree_path} = task) do
    case Tools.run("git", ["merge-base", "origin/#{base_branch(task)}", "HEAD"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _no_merge_base -> "HEAD"
    end
  end

  # Every project is required to name a default branch, so there is nothing to
  # fall back to: a project that cannot be read is a broken invariant.
  defp base_branch(%Task{project_id: project_id}) do
    %Project{default_branch: default_branch} = Repo.get(Project, project_id)

    default_branch
  end
end

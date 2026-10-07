defmodule Rail.Pipeline.Utils.BuildTask do
  @moduledoc """
  The changeset that inserts a task for an issue, with its id, worktree and scratch directory drawn.
  """

  import Rail.Pipeline.Utils.ScratchPath

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Builds the insert changeset for `issue`'s task in `project`, with `attrs` such as its stage on top.
  """
  def build_task(%Project{} = project, %Issue{} = issue, attrs) do
    name = worktree_name(issue)

    # The id is drawn here rather than at insert so the scratch directory can be
    # named after it: every later stage reads the path off the row instead of
    # recomputing it and risking a different answer.
    id = UXID.generate!(prefix: "tsk")

    attrs =
      Map.merge(
        %{
          issue_id: issue.id,
          worktree_name: name,
          worktree_path: Path.join(project.clone_path, ".worktrees/#{name}"),
          scratch_path: scratch_path(project.id, id)
        },
        attrs
      )

    Task.changeset(%Task{id: id}, attrs, project.id)
  end

  defp worktree_name(%Issue{branch_name: branch}) when is_binary(branch) and branch != "", do: branch

  defp worktree_name(%Issue{identifier: identifier}) when is_binary(identifier) do
    identifier |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/i, "-")
  end
end

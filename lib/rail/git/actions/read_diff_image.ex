defmodule Rail.Git.Actions.ReadDiffImage do
  @moduledoc """
  A picture the diff changed, as one side of it reads, so the pane can show it
  rather than only name it.

  The old side is the file at the diff's base, the new side the file in the
  worktree or at the commit, the same revisions the diff itself was read at.
  """

  import Rail.Git.Utils.DiffSides
  import Rail.Git.Utils.FileContent
  import Rail.Git.Utils.ImageType

  alias Rail.Pipeline.Schemas.Task

  @sha ~r/\A[0-9a-f]{7,40}\z/

  @doc """
  Returns `{:ok, type, bytes}` for `path` on `side` (`:old` or `:new`) of `task`'s
  diff under `filter`, or `{:error, :not_found}`.

  Only a picture is read, whatever the path, since the path comes from a page.
  """
  def read_diff_image(%Task{} = task, path, side, filter) when is_binary(path) and side in [:old, :new] do
    with type when is_binary(type) <- image_type(path),
         true <- Task.worktree_present?(task),
         true <- known?(filter),
         bytes when is_binary(bytes) <- file_content(task.worktree_path, path, revision(task, filter, side)) do
      {:ok, type, bytes}
    else
      _unreadable -> {:error, :not_found}
    end
  end

  # The sha comes from a page, so only a commit name, never an option, reaches git.
  defp known?({:commit, sha}), do: is_binary(sha) and sha =~ @sha
  defp known?(filter), do: filter in [:branch, :uncommitted]

  defp revision(task, filter, :old), do: task |> diff_sides(filter) |> elem(0)
  defp revision(task, filter, :new), do: task |> diff_sides(filter) |> elem(1)
end

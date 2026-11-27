defmodule Rail.Git.Actions.ReadDiffImage do
  @moduledoc """
  A picture the diff changed, as one side of it reads, so the pane can show it
  rather than only name it.

  The old side is the file at the diff's base, the new side the file in the
  working tree or at the commit, the same revisions the diff itself was read at.
  """

  import Rail.Git.Utils.DiffSides
  import Rail.Git.Utils.FileContent
  import Rail.Git.Utils.ImageType
  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task

  @sha ~r/\A[0-9a-f]{7,40}\z/

  @doc """
  Returns `{:ok, type, bytes}` for `path` on `side` (`:old` or `:new`) of `task`'s
  diff under `filter`, or `{:error, :not_found}`.

  Only a picture is read, whatever the path, since the path comes from a page.
  """
  def read_diff_image(%Task{} = task, path, side, filter) when is_binary(path) and side in [:old, :new] do
    with type when is_binary(type) <- image_type(path),
         true <- known?(filter),
         %{repo: repo} = work_tree <- work_tree(task),
         {old, new} = diff_sides(task, work_tree, filter),
         bytes when is_binary(bytes) <- file_content(repo, path, if(side == :old, do: old, else: new)) do
      {:ok, type, bytes}
    else
      _unreadable -> {:error, :not_found}
    end
  end

  # The sha comes from a page, so only a commit name, never an option, reaches git.
  defp known?({:commit, sha}), do: is_binary(sha) and sha =~ @sha
  defp known?(filter), do: filter in [:branch, :uncommitted]
end

defmodule Rail.Git.Actions.ListDefaultBranchPaths do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  The files among `paths` on `project`'s fetched `origin/<default_branch>`, as a `MapSet`, or nil when git cannot read
  the clone, so a caller can tell "on no branch" from "could not ask".
  """
  def list_default_branch_paths(%Project{}, []), do: MapSet.new()

  # No clone lock: a fetch moves the ref atomically, so a read sees one side of it.
  def list_default_branch_paths(%Project{} = project, paths) when is_list(paths) do
    case Tools.run("git", ["ls-tree", "-z", "refs/remotes/origin/#{project.default_branch}", "--" | paths],
           cd: project.clone_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> output |> String.split(<<0>>, trim: true) |> Enum.flat_map(&blob_path/1) |> MapSet.new()
      {_output, _code} -> nil
    end
  end

  # A directory named on its own lists as a tree entry, and only files are on the branch the way a card means.
  defp blob_path(entry) do
    case String.split(entry, "\t", parts: 2) do
      [<<_mode::binary-size(6), " blob ", _object::binary>>, path] -> [path]
      _tree_or_submodule -> []
    end
  end
end

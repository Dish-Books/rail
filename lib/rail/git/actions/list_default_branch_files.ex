defmodule Rail.Git.Actions.ListDefaultBranchFiles do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Lists the files directly under `directory` on `project`'s fetched `origin/<default_branch>`, as paths from
  the repository root, the listing sibling of `read_default_branch_file/2`. A directory the branch does not
  have lists as `{:ok, []}`; `{:error, output}` is for anything git could not show.
  """
  # No clone lock, for the same reason as the read: a fetch moves the ref atomically.
  def list_default_branch_files(%Project{} = project, directory) when is_binary(directory) do
    tree = "refs/remotes/origin/#{project.default_branch}"
    directory = String.trim_trailing(directory, "/") <> "/"

    case Tools.run("git", ["ls-tree", "-z", tree, "--", directory], cd: project.clone_path, stderr_to_stdout: true) do
      # NUL-separated, so a path is never quoted, and only blobs, so a subdirectory is left out.
      {output, 0} ->
        paths =
          for entry <- String.split(output, <<0>>, trim: true),
              [meta, path] = String.split(entry, "\t", parts: 2),
              match?([_mode, "blob", _sha], String.split(meta, " ")),
              do: path

        {:ok, paths}

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end
end

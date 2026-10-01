defmodule Rail.Git.Actions.ReadDefaultBranchFile do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Reads `path` as it stands on `project`'s fetched `origin/<default_branch>`, so
  only what is merged and fetched is seen, never a task branch or the clone's own
  working tree. Returns `{:ok, text}`, or `{:error, output}` for anything git
  could not show.
  """
  # No clone lock: a fetch moves the ref atomically, so a read sees one side of it.
  def read_default_branch_file(%Project{} = project, path) when is_binary(path) do
    case Tools.run("git", ["show", "refs/remotes/origin/#{project.default_branch}:#{path}"],
           cd: project.clone_path,
           stderr_to_stdout: true
         ) do
      # A blob show writes nothing to stderr when it succeeds, so the output is the file.
      {text, 0} -> {:ok, text}
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end

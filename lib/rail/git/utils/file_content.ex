defmodule Rail.Git.Utils.FileContent do
  @moduledoc false

  alias Rail.Tools

  @doc """
  The bytes of `path` as it was at the commit `revision` in the repository at `repo_path`, or `nil` when there is no
  file there to read.
  """
  # `cat-file blob` rather than `show`, which lists a directory instead of failing.
  def file_content(repo_path, path, revision) when is_binary(revision) do
    case Tools.run("git", ["cat-file", "blob", "#{revision}:#{path}"], cd: repo_path, stderr_to_stdout: true) do
      {content, 0} -> content
      _absent -> nil
    end
  end
end

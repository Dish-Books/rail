defmodule Rail.Git.Actions.EnsureClone do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Clones a repository if not present; fetches updates if already cloned.
  """
  def ensure_clone(clone_url, clone_path) when is_binary(clone_url) and is_binary(clone_path) do
    git_dir = Path.join(clone_path, ".git")

    if File.dir?(clone_path) and (File.dir?(git_dir) or File.exists?(git_dir)) do
      case ToolEnv.run("git", ["fetch", "--all", "--prune"],
             cd: clone_path,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:ok, clone_path}

        {output, _code} ->
          {:error, String.trim(output)}
      end
    else
      File.mkdir_p!(Path.dirname(clone_path))

      case ToolEnv.run("git", ["clone", clone_url, clone_path], stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, clone_path}

        {output, _code} ->
          {:error, String.trim(output)}
      end
    end
  end
end

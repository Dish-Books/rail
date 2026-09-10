defmodule RailTest.GitHelpers do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Creates a real temporary git repository on disk with initial commits.
  Registers an on_exit callback to clean up the directory when the test finishes.
  """
  def create_temp_git_repo(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "rail_git_test")
    branch = Keyword.get(opts, :branch, "main")
    initial_commit? = Keyword.get(opts, :initial_commit, true)

    unique_id = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{unique_id}")
    File.mkdir_p!(dir)

    git!(dir, ["init", "-b", branch])
    git!(dir, ["config", "user.name", "Rail Test"])
    git!(dir, ["config", "user.email", "test@rail.local"])
    git!(dir, ["config", "commit.gpgsign", "false"])

    if initial_commit? do
      File.write!(Path.join(dir, "tracked.txt"), "one\n")
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "initial commit"])
    end

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf(dir)
    end)

    dir
  end

  @doc """
  Executes a git command in the given directory and raises if it fails.
  """
  def git!(dir, args) do
    case ToolEnv.run("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} ->
        out

      {err, code} ->
        raise "git #{Enum.join(args, " ")} in #{dir} failed (exit #{code}): #{err}"
    end
  end
end

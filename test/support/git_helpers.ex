defmodule RailTest.GitHelpers do
  @moduledoc false

  alias Rail.Tools

  require Logger

  # Under the 60s a test gets, so a git that never returns says what it was rather than timing out.
  @git_timeout_ms 30_000

  @doc """
  Creates a real temporary git repository on disk with initial commits.
  Registers an on_exit callback to clean up the directory when the test finishes.
  """
  def create_temp_git_repo(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "rail_git_test")
    branch = Keyword.get(opts, :branch, "main")
    initial_commit? = Keyword.get(opts, :initial_commit, true)

    # unique_integer restarts per VM, so a dir left behind by a killed run can
    # collide; the random suffix keeps each run's repos to itself.
    unique_id = System.unique_integer([:positive])
    salt = Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
    dir = Path.join("/tmp", "#{prefix}_#{unique_id}_#{salt}")
    File.rm_rf!(dir)
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
  def git!(dir, args), do: git!(dir, args, 1)

  defp git!(dir, args, retries) do
    command = Task.async(fn -> Tools.run("git", args, cd: dir, stderr_to_stdout: true) end)

    case Task.yield(command, @git_timeout_ms) do
      {:ok, {out, 0}} ->
        out

      {:ok, {err, code}} ->
        raise "git #{Enum.join(args, " ")} in #{dir} failed (exit #{code}): #{err}"

      # coveralls-ignore-start (a git that never returns; CI has seen a plain init and commit do it,
      # with no git left running, so the command is run once more and what held it is logged)
      nil ->
        report = hung_report(command, dir, args)
        Task.shutdown(command, :brutal_kill)

        if retries > 0 do
          Logger.warning(report <> "Running it once more.")
          git!(dir, args, retries - 1)
        else
          raise report
        end

        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start
  # Where the waiting process is, whether its git is still alive, and whatever started last,
  # which is likely what holds the hung command's output open.
  defp hung_report(command, dir, args) do
    ports =
      for port <- Port.list(), Port.info(port, :connected) == {:connected, command.pid}, do: Port.info(port, :os_pid)

    """
    git #{Enum.join(args, " ")} in #{dir} was still running after #{div(@git_timeout_ms, 1000)}s.
    The waiting process: #{inspect(Process.info(command.pid, [:status, :current_stacktrace, :messages]))}
    Its ports' OS processes: #{inspect(ports)}
    The newest processes on this machine:
    #{ps() |> String.split("\n", trim: true) |> Enum.take(-40) |> Enum.join("\n")}
    """
  end

  defp ps do
    {processes, _code} =
      System.cmd("ps", ["-eo", "pid,ppid,stat,etime,args", "--sort=start_time"], stderr_to_stdout: true, env: [])

    processes
  end

  # coveralls-ignore-stop
end

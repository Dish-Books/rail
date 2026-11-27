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
  Lays a task out as Rail does under the `:local` runtime: `origin` (`remote`), the project's clone of it (`clone`),
  and a task of a ticket in that project with its repository (`repo`) and its checkout (`checkout`), made by
  `Rail.Git.get_or_create_worktree/2`. `:project` and `:task` take attributes for each. Needs the test's database.
  """
  def create_task_checkout(opts \\ []) do
    unique = System.unique_integer([:positive])
    scope = Rail.Scope.system_scope()
    remote = create_temp_git_repo(prefix: "rail_task_remote")
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    clone = Path.join(System.tmp_dir!(), "rail_task_clone_#{unique}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(clone) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", remote, clone])

    attrs =
      Map.merge(
        %{
          name: "Task Checkout #{unique}",
          github_repo: "example/task-checkout-#{unique}",
          github_installation_id: 1,
          default_branch: "main",
          key: "TC#{unique}",
          clone_path: clone
        },
        Map.new(Keyword.get(opts, :project, []))
      )

    {:ok, project} = Rail.Projects.create_project(scope, attrs)
    {:ok, issue} = Rail.Issues.create_issue(scope, project, %{title: "Issue", description: "A task's checkout"})
    {:ok, task} = Rail.Pipeline.create_task(issue, :engineer)
    {:ok, task} = Rail.Pipeline.update_task(task, Map.new(Keyword.get(opts, :task, [])))
    ExUnit.Callbacks.on_exit(fn -> Enum.each([Path.dirname(task.worktree_path), task.scratch_path], &File.rm_rf/1) end)
    Req.Test.stub(Rail.GitHub.Client, &Req.Test.json(&1, %{"token" => "ghs_installation_token"}))
    {:ok, checkout} = Rail.Git.get_or_create_worktree(project, task)

    %{
      remote: remote,
      clone: clone,
      project: project,
      issue: issue,
      task: task,
      repo: Rail.Pipeline.Schemas.Task.repo_path(task),
      checkout: checkout
    }
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

defmodule Rail.Tools.Actions.StartCommandProcess do
  @moduledoc false

  import Rail.Tools.Utils.EnqueueSandbox
  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @exit_var "__RAIL_EXIT_PATH"
  @default_timeout_ms to_timeout(minute: 30)

  @doc """
  Runs `command` through `/bin/sh` in `run`'s worktree as an OS process of `kind`,
  in a sandbox holding what the run's role reserves, followed like an agent's and
  settled by `run_finished/3` when it exits.

  Takes `:timeout_ms`, after which it is stopped, counted from when it starts
  rather than from when it joined the line, `:env`, and `:head_sha`, the commit it
  is being run against. Returns `{:ok, os_process}` with `:run` and `:task`
  loaded, running or waiting, or `{:error, reason}`.
  """
  def start_command_process(%Run{} = run, kind, command, opts \\ []) when is_binary(command) do
    %Run{task: %Task{} = task} = run = Repo.preload(run, [:task, :role])
    os_process = insert_os_process(run, kind, command, opts)

    env =
      task
      |> worktree_env()
      |> Map.merge(Keyword.get(opts, :env, %{}))
      |> Map.put(@exit_var, OsProcess.exit_path(os_process))

    spec = %{
      "executable" => "/bin/sh",
      "args" => ["-c", script(command)],
      "env" => env,
      "cwd" => task.worktree_path,
      "stdout_path" => os_process.stream_path,
      "stderr_path" => os_process.stream_path,
      "timeout_ms" => Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }

    case enqueue_sandbox(os_process, run, spec) do
      {:ok, os_process} -> {:ok, %{os_process | run: run, task: task}}
      {:waiting, os_process} -> {:ok, %{os_process | run: %{run | status: :waiting_for_resources}, task: task}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The status goes to a file as well as the port, because the port dies with the
  # BEAM and a command outlives it. A subshell, so a command that exits still gets it written.
  defp script(command) do
    "(\n#{command}\n)\nstatus=$?\necho $status > \"$#{@exit_var}\"\nexit $status\n"
  end

  defp insert_os_process(%Run{} = run, kind, command, opts) do
    id = UXID.generate!(prefix: "proc")
    stream_path = Path.join([run.task.scratch_path, "streams", "#{id}.log"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")

    %OsProcess{id: id}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: kind,
      command: command,
      stream_path: stream_path,
      status: :starting,
      started_at: DateTime.utc_now(),
      head_sha: Keyword.get(opts, :head_sha)
    })
    |> Repo.insert!()
  end
end

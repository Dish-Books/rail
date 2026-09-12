defmodule Rail.Runs.Actions.StartOsProcess do
  @moduledoc false

  import Rail.Runs.Utils.EnsureExecutable

  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  @doc """
  Spawns a detached CLI runner for a run, records the `runs` row, starts its
  Follower, and settles the dispatch either way.

  Everything the spawn needs is derived from the run: the executable from
  its role's backend, which is an absolute path, and the working directory and
  stream path from its task. `argv` is arguments only. Nothing is wired in for
  the exit: `run_finished/3` works from the row the spawn writes.

  A spawn is a spawn whether it carries a stage's work or a message the human
  just typed, so nothing here asks which it was and nothing here touches the
  task. Returns `{:ok, os_process}` with its `:run` and `:task` loaded, or
  `{:error, {:spawn_failed, reason, run}}` with the reason recorded on the run.

  Returns `{:error, :dispatch_disabled}` when dispatch is switched off. This is
  the one gate on invoking an agent CLI, so
  it sits here rather than at each of the places that decide to: Rail still moves
  tasks, records runs and renders everything, it just never spawns.
  """
  def start_os_process(%Run{} = run, argv) do
    if dispatch_disabled?() do
      {:error, :dispatch_disabled}
    else
      spawn_os_process(run, argv)
    end
  end

  defp dispatch_disabled?, do: Application.get_env(:rail, :no_dispatch, false)

  defp spawn_os_process(%Run{} = run, argv) do
    run = Repo.preload(run, [:task, role: :backend])
    %Run{task: %Task{} = task, role: %Role{backend: %Backend{} = backend}} = run

    executable = backend.executable_path
    stream_path = prepare_stream_files(task, run)
    os_process = insert_os_process(run, stream_path)

    result =
      case ensure_executable(executable, os_process, run) do
        :ok -> launch(os_process, run, executable, argv, stream_path, task)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, os_process} -> finalize(task, run, os_process)
      {:error, reason} -> fail(run, reason)
    end
  end

  defp finalize(task, run, os_process) do
    {:ok, run} =
      run
      |> Run.changeset(%{pending_answer: nil, error: nil})
      |> Repo.update()


    {:ok, %{os_process | run: run, task: task}}
  end

  # A failure that already said what went wrong keeps its own words: the missing
  # binary check settles the run before returning here.
  defp fail(run, reason) do
    run = Repo.get!(Run, run.id)

    run =
      if is_binary(run.error) do
        run
      else
        run |> Run.changeset(%{error: "Failed to spawn runner: #{inspect(reason)}"}) |> Repo.update!()
      end


    {:error, {:spawn_failed, reason, run}}
  end

  defp insert_os_process(run, stream_path) do
    attrs = %{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      node: to_string(Node.self()),
      status: :starting,
      started_at: DateTime.utc_now()
    }

    %OsProcess{}
    |> OsProcess.changeset(attrs)
    |> Repo.insert!()
  end

  # One stream per run, under the task's scratch directory, so concurrent runs
  # on a task cannot truncate each other's logs.
  defp prepare_stream_files(%Task{scratch_path: scratch_path}, %Run{id: id}) do
    stream_path = Path.join([scratch_path, "streams", "#{id}.ndjson"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")
    stream_path
  end

  defp launch(os_process, run, executable, args, stream_path, task) do
    spawn_opts = [
      stdout_path: stream_path,
      stderr_path: "#{stream_path}.err",
      cd: task.worktree_path
    ]

    case Tools.spawn_os_process(executable, args, spawn_opts) do
      {:ok, port, os_pid} ->
        {:ok, os_process} =
          os_process
          |> OsProcess.changeset(%{status: :running, os_pid: os_pid})
          |> Repo.update()

        follow(os_process, run, port)

      # coveralls-ignore-start (defensive: port died before reporting a PID)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # The run is already loaded down to its backend, so handing it over on the row
  # saves the Follower the preload.
  defp follow(%OsProcess{} = os_process, run, port) do
    os_process = %{os_process | run: run}

    with {:ok, _follower_pid} <- FollowerSupervisor.start_follower(os_process, port: port) do
      {:ok, os_process}
    end
  end
end

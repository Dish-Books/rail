defmodule Rail.Tools.Utils.LaunchSandbox do
  @moduledoc false

  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.LoginMounts
  import Rail.Tools.Utils.RedirectedCommand

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @gib 1024 ** 3

  @doc """
  Starts a waiting process from its launch spec, marks it running and hands it to
  a Follower. `os_process` must carry its run, preloaded down to its `role`, its
  `backend`, and its task down to its `project`.

  `:local` spawns beside Rail. `:docker` runs it in a container of its own, which
  outlives Rail. Its CPUs are the row's share rather than a cap: `capacity` is what `Rail.Tools.get_sandbox_capacity/0`
  said the machine has, and a sandbox may use all of it while it is idle. Its
  clock starts now, so time spent in line never counts against a command's
  timeout. Returns `{:ok, os_process}`, or `{:error, reason}` with the row failed
  when nothing started.
  """
  def launch_sandbox(%OsProcess{runtime: runtime} = os_process, %{cpus: _cpus} = capacity) do
    spec = OsProcess.launch_spec(os_process)

    case start(runtime, os_process, spec, capacity) do
      {:ok, attrs, port} ->
        now = DateTime.utc_now()
        deadline_at = if is_integer(spec["timeout_ms"]), do: DateTime.add(now, spec["timeout_ms"], :millisecond)

        os_process
        |> OsProcess.changeset(
          Map.merge(%{status: :running, started_at: now, deadline_at: deadline_at, launch: nil}, attrs)
        )
        |> Repo.update!()
        |> follow(port)

      {:error, reason} ->
        os_process
        |> OsProcess.changeset(%{
          status: :failed,
          ended_reason: :failed_to_start,
          ended_at: DateTime.utc_now(),
          exit_code: -1,
          launch: nil
        })
        |> Repo.update!()

        {:error, reason}
    end
  end

  defp start(:local, %OsProcess{} = os_process, spec, _capacity) do
    opts =
      [
        cd: spec["cwd"],
        env: spec["env"],
        stdout_path: spec["stdout_path"],
        stderr_path: spec["stderr_path"]
      ] ++ if(spec["stdin_path"], do: [stdin_path: spec["stdin_path"]], else: [])

    case Tools.spawn_os_process(spec["executable"], spec["args"], opts) do
      {:ok, port, os_pid} ->
        {:ok, %{os_pid: os_pid}, port}

      # A command quick enough to be gone before its pid could be read has already
      # written how it exited, which is all its Follower needs to settle it.
      {:error, :no_os_pid} when os_process.kind != :agent ->
        {:ok, %{}, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The sandbox sees its folders at the paths Rail does, so each is checked here:
  # Docker would otherwise create a missing one, owned by root.
  defp start(:docker, %OsProcess{} = os_process, spec, capacity) do
    {shell, args, env} =
      redirected_command(spec["executable"], spec["args"],
        env: spec["env"],
        stdout_path: spec["stdout_path"],
        stderr_path: spec["stderr_path"],
        stdin_path: spec["stdin_path"]
      )

    with true <- File.dir?(spec["cwd"]) || {:error, {:bad_cwd, spec["cwd"]}},
         {:ok, %{binds: binds, tmpfs: tmpfs}} <- mounts(os_process, spec["cwd"]),
         body = body(os_process, spec, capacity, {shell, args, env}, binds, tmpfs),
         {:ok, %{"Id" => id}} <- Docker.create_container(os_process.id, body),
         {:ok, _started} <- start_container(id) do
      {:ok, %{container_id: id}, nil}
    end
  end

  # CPU time is weighed rather than capped: a sandbox takes whatever the others
  # leave idle, and when they all want more, each gets its reservation's share.
  # The ceiling is the machine less its headroom, so Rail, Postgres and project
  # services keep theirs. Memory is not limited at all: a sandbox takes what it
  # needs, and if the machine runs out the kernel is told to stop a sandbox
  # before it stops Rail or Postgres.
  defp body(%OsProcess{} = os_process, spec, capacity, {shell, args, env}, binds, tmpfs) do
    %{
      "Image" => Rail.sandbox_image(),
      "Cmd" => [shell | args],
      "Env" => env |> env() |> schedulers(os_process) |> Enum.map(fn {key, value} -> "#{key}=#{value}" end),
      "WorkingDir" => spec["cwd"],
      "User" => "1000:1000",
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => binds,
        "Tmpfs" => tmpfs,
        "CpuShares" => round(os_process.reserved_cpus * 1024),
        "NanoCpus" => capacity.cpus * 1_000_000_000,
        "OomScoreAdj" => 500,
        "Init" => true,
        "ShmSize" => Rail.sandbox_shm_size_gb() * @gib
      }
    }
  end

  # A worktree's .git writes into its project clone's git folder, so such a task keeps the whole mount until it ends:
  # nothing below protects its git config, or its clone's.
  defp mounts(%OsProcess{task: %Task{project: %Project{clone_path: clone_path}} = task} = os_process, cwd) do
    worktrees = Path.join(clone_path, ".worktrees")

    if String.starts_with?(cwd, worktrees <> "/") do
      {:ok, %{binds: Rail.sandbox_binds(), tmpfs: %{}}}
    else
      git_dir = Path.join(cwd, ".git")
      writable = [Path.dirname(cwd), task.scratch_path, git_dir]
      read_only = Enum.filter([clone_path, Rail.mise_data_dir()], &is_binary/1)

      case Enum.find(writable ++ read_only, &(not File.dir?(&1))) do
        missing when is_binary(missing) ->
          {:error, {:bad_cwd, missing}}

        nil ->
          login = login(os_process, cwd)
          # Old tasks' worktrees and triage checkouts live in the clone, and are no business of this task.
          hidden = if File.dir?(worktrees), do: %{worktrees => "uid=1000,gid=1000,mode=0700"}, else: %{}
          locked = Enum.map(locked_git(git_dir), &"#{&1}:#{&1}:ro")

          {:ok,
           %{
             binds: Enum.map(writable, &"#{&1}:#{&1}") ++ Enum.map(read_only, &"#{&1}:#{&1}:ro") ++ locked ++ login.binds,
             tmpfs: Map.merge(hidden, login.tmpfs)
           }}
      end
    end
  end

  # Rail runs git in the checkout, so of its .git the sandbox writes only what git reads as data, its objects and
  # refs. Not the config, which Rail writes whole before each turn (Rail.Git.write_checkout_config/2) and which alone
  # can name a filter, merge driver, hook or program for git to run; not the info folder, whose attributes would name
  # them; not the hooks. The .git folder is a mount of its own, so it cannot be moved aside for another, and each of
  # these is made if missing, so Docker has something to mount over.
  defp locked_git(git_dir) do
    config = Path.join(git_dir, "config")
    folders = Enum.map(["info", "hooks"], &Path.join(git_dir, &1))
    Enum.each(folders, &File.mkdir_p!/1)
    File.touch!(config)
    [config | folders]
  end

  # Only an agent runs the CLI; its own conversations stay open so the next turn can resume them.
  defp login(%OsProcess{kind: :agent, backend: %Backend{} = backend}, cwd),
    do: login_mounts(backend, [Backend.session_dir(backend, cwd)])

  defp login(%OsProcess{}, _cwd), do: %{binds: [], tmpfs: %{}}

  # The BEAM sizes itself to the ceiling, and ExUnit runs twice as many cases as
  # it has schedulers, so a CI suite on a busy machine would pile far more work on
  # its share than its reservation. Pinning CI's schedulers to the reservation
  # keeps its tests in proportion; a flag the project set itself comes after, and
  # wins. An agent's turn keeps the whole ceiling for its compiles.
  defp schedulers(env, %OsProcess{kind: :ci, reserved_cpus: cpus}) do
    Map.put(env, "ERL_FLAGS", String.trim("+S #{cpus}:#{cpus} #{env["ERL_FLAGS"]}"))
  end

  defp schedulers(env, %OsProcess{}), do: env

  defp start_container(id) do
    with {:error, reason} <- Docker.start_container(id) do
      _removed = Docker.remove_container(id)
      {:error, reason}
    end
  end

  defp follow(%OsProcess{} = os_process, port) do
    with {:ok, _follower_pid} <- FollowerSupervisor.start_follower(os_process, port: port) do
      {:ok, os_process}
    end
  end
end

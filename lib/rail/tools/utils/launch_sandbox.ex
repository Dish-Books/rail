defmodule Rail.Tools.Utils.LaunchSandbox do
  @moduledoc false

  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.RedirectedCommand

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  @gib 1024 ** 3

  @doc """
  Starts a waiting process from its launch spec, marks it running and hands it to
  a Follower. `os_process` must carry its run, preloaded down to `role: :backend`.

  `:local` spawns beside Rail. `:docker` runs it in a container of its own, which
  outlives Rail and cannot use more than the row reserves. Its clock starts now,
  so time spent in line never counts against a command's timeout. Returns
  `{:ok, os_process}`, or `{:error, reason}` with the row failed when nothing started.
  """
  def launch_sandbox(%OsProcess{runtime: runtime} = os_process) do
    spec = OsProcess.launch_spec(os_process)

    case start(runtime, os_process, spec) do
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

  defp start(:local, %OsProcess{} = os_process, spec) do
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

  # The sandbox sees /srv/rail at the same path Rail does, so the worktree is
  # checked here: Docker would otherwise create a missing one, owned by root.
  defp start(:docker, %OsProcess{} = os_process, spec) do
    config = Application.get_env(:rail, :sandbox, [])

    {shell, args, env} =
      redirected_command(spec["executable"], spec["args"],
        env: spec["env"],
        stdout_path: spec["stdout_path"],
        stderr_path: spec["stderr_path"],
        stdin_path: spec["stdin_path"]
      )

    body = %{
      "Image" => Keyword.fetch!(config, :image),
      "Cmd" => [shell | args],
      "Env" => env |> env() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end),
      "WorkingDir" => spec["cwd"],
      "User" => "1000:1000",
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => Keyword.fetch!(config, :binds),
        "NanoCpus" => os_process.reserved_cpus * 1_000_000_000,
        # Swap is capped at the same figure, so a sandbox cannot use more by swapping.
        "Memory" => os_process.reserved_memory_gb * @gib,
        "MemorySwap" => os_process.reserved_memory_gb * @gib,
        "Init" => true,
        "ShmSize" => Keyword.get(config, :shm_size_gb, 1) * @gib
      }
    }

    with true <- File.dir?(spec["cwd"]) || {:error, {:bad_cwd, spec["cwd"]}},
         {:ok, %{"Id" => id}} <- Docker.create_container(os_process.id, body),
         {:ok, _started} <- start_container(id) do
      {:ok, %{container_id: id}, nil}
    end
  end

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

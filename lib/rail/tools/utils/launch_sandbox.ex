defmodule Rail.Tools.Utils.LaunchSandbox do
  @moduledoc false

  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.LocalMcpUrl
  import Rail.Tools.Utils.StartSandbox

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Starts a waiting process from its launch spec, marks it running and hands it to
  a Follower. `os_process` must carry its run, preloaded down to its `role`, its
  `backend`, and its task down to its `project`.

  `:local` spawns beside Rail. `:docker` runs it in its task's sandbox, whose container outlives Rail. Its CPUs are the
  row's share rather than a cap: `capacity` is what `Rail.Tools.get_sandbox_capacity/0` said the machine has, and a
  sandbox may use all of it while it is idle. Its
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
        env: Map.put(spec["env"] || %{}, "RAIL_MCP_URL", local_mcp_url()),
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

  # The command goes to its task's sandbox, whose runner starts it from `launch` once its Follower asks: the row keeps
  # that until the runner says it started.
  defp start(:docker, %OsProcess{} = os_process, spec, capacity) do
    with {:ok, sandbox} <- start_sandbox(os_process, capacity) do
      exec = %{
        "argv" => [spec["executable"] | spec["args"]],
        "env" => spec["env"] |> claude_env(os_process) |> env() |> schedulers(os_process),
        "cwd" => spec["cwd"],
        "files" => claude_files(os_process, spec),
        "claude" => os_process.kind == :agent,
        "stdin" => spec["stdin_path"] && Base.encode64(File.read!(spec["stdin_path"])),
        "stderr" => if(spec["stdout_path"] == spec["stderr_path"], do: "merge", else: "separate")
      }

      {:ok, %{sandbox_id: sandbox.id, container_id: sandbox.container_id, launch: Jason.encode!(exec)}, nil}
    end
  end

  # An agent's Claude keeps no login: the runner points it at Rail's proxy, and it sends nothing past it.
  defp claude_env(env, %OsProcess{kind: :agent}) do
    Map.merge(env, %{
      "CLAUDE_CONFIG_DIR" => Backend.sandbox_config_dir(),
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
    })
  end

  defp claude_env(env, %OsProcess{}), do: env

  # The checkout is trusted, as accepting Claude Code's dialog there would, and a conversation the turn resumes is put
  # back where the CLI looks for it: a new container has neither.
  defp claude_files(%OsProcess{kind: :agent, backend: %Backend{} = backend}, %{"cwd" => cwd, "args" => args}) do
    trust = %{"projects" => %{cwd => %{"hasTrustDialogAccepted" => true}}}

    config = %{
      "path" => Path.join(Backend.sandbox_config_dir(), ".claude.json"),
      "data" => encode(trust),
      "mode" => 0o600
    }

    transcript =
      with {_before, ["--resume", conversation_id | _rest]} <- Enum.split_while(args, &(&1 != "--resume")),
           name = "#{conversation_id}.jsonl",
           {:ok, data} <- File.read(Path.join(Backend.session_dir(backend, cwd), name)) do
        [%{"path" => Path.join(Backend.sandbox_session_dir(cwd), name), "data" => Base.encode64(data), "mode" => 0o600}]
      else
        _none -> []
      end

    [config | transcript]
  end

  defp claude_files(%OsProcess{}, _spec), do: []

  defp encode(map), do: map |> Jason.encode!() |> Base.encode64()

  # The BEAM sizes itself to the ceiling, and ExUnit runs twice as many cases as
  # it has schedulers, so a CI suite on a busy machine would pile far more work on
  # its share than its reservation. Pinning CI's schedulers to the reservation
  # keeps its tests in proportion; a flag the project set itself comes after, and
  # wins. An agent's turn keeps the whole ceiling for its compiles.
  defp schedulers(env, %OsProcess{kind: :ci, reserved_cpus: cpus}) do
    Map.put(env, "ERL_FLAGS", String.trim("+S #{cpus}:#{cpus} #{env["ERL_FLAGS"]}"))
  end

  defp schedulers(env, %OsProcess{}), do: env

  defp follow(%OsProcess{} = os_process, port) do
    with {:ok, _follower_pid} <- FollowerSupervisor.start_follower(os_process, port: port) do
      {:ok, os_process}
    end
  end
end

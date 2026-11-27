defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.LocalMcpUrl
  import Rail.Tools.Utils.LoginMounts
  import Rail.Tools.Utils.PickBackend
  import Rail.Tools.Utils.RejectToken

  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend

  # How the CLI's last stream-json line reports a token Claude would not take.
  @authentication_failed ~r/"error":\s*"authentication_failed"/
  @poll_ms 1_000

  @doc """
  Runs `role`'s CLI with `argv` and waits for it, for work that has no run to
  follow, such as a triage pass. It runs on the account a new conversation of
  the role would, picked by the same rules, so a signed-out account never runs.
  A pass whose only accounts are signed out does not start, rather than wait.

  Takes `:env` (merged over the account's own), `:cd`, `:mounts`, `:read_only_mounts`, `:timeout` and `:into`. Under
  Docker it runs in a container that sees only `:cd`, the mounts and its account's sign-in, and `:into` does not apply.
  Returns `{:ok, output}`, `{:error, {:exit, code, output}}`, `{:error, :timeout}`,
  `{:error, {:waiting_for_usage, resets_at}}` when every account is used up,
  `{:error, :backend_signed_out}` when only signed-out accounts offer the model,
  an error sentence when none offers it, or
  `{:error, :dispatch_disabled}` under the same gate as `start_os_process/2`.
  """
  def run_agent(%Role{} = role, argv, opts) when is_list(argv) do
    if Application.get_env(:rail, :no_dispatch, false) do
      {:error, :dispatch_disabled}
    else
      case pick_backend(role.cli, role.model, nil) do
        {:ok, backend} -> run(backend, argv, opts)
        {:wait, resets_at} -> {:error, {:waiting_for_usage, resets_at}}
        {:held, _signed_out} -> {:error, :backend_signed_out}
        {:error, :no_account} -> {:error, Backend.no_account_error(role.model, role.name)}
      end
    end
  end

  defp run(%Backend{} = backend, argv, opts) do
    env = backend |> backend_env() |> Map.put("RAIL_MCP_URL", local_mcp_url()) |> Map.merge(Keyword.get(opts, :env, %{}))

    case execute(Rail.sandbox_runtime(), backend, argv, env, opts) do
      {output, 0} ->
        {:ok, output}

      {output, code} when is_integer(code) ->
        if output =~ @authentication_failed, do: reject_token(backend)
        {:error, {:exit, code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(:local, %Backend{} = backend, argv, env, opts) do
    run_opts = [env: env, stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :timeout, :into])
    Tools.run(backend.executable_path, argv, run_opts)
  end

  # Docker's own PID namespace and no socket keep Rail's processes, their environment and the host out of reach.
  defp execute(:docker, %Backend{} = backend, argv, env, opts) do
    cd = Keyword.fetch!(opts, :cd)
    timeout = Keyword.get(opts, :timeout, :infinity)
    read_only = Keyword.get(opts, :read_only_mounts, [])
    writable = Enum.uniq([cd | Keyword.get(opts, :mounts, [])]) -- read_only

    # A container whose caller is gone stops on its own at the same limit.
    cmd =
      if is_integer(timeout),
        do: ["timeout", "-k", "5", "#{div(timeout, 1000)}", backend.executable_path | argv],
        else: [backend.executable_path | argv]

    # Docker would create a missing folder, owned by root.
    with nil <- Enum.find(writable ++ read_only, &(not File.dir?(&1))),
         %{binds: login_binds, tmpfs: tmpfs} = login_mounts(backend, []),
         binds = Enum.map(writable, &"#{&1}:#{&1}") ++ Enum.map(read_only, &"#{&1}:#{&1}:ro") ++ login_binds,
         {:ok, %{"Id" => id}} <- Docker.create_agent_container(body(cmd, env, cd, binds, tmpfs)) do
      try do
        wait(id, timeout)
      after
        _removed = Docker.remove_container(id, force: true)
      end
    else
      missing when is_binary(missing) -> {:error, {:bad_cwd, missing}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp body(cmd, env, cd, binds, tmpfs) do
    %{
      "Image" => Rail.sandbox_image(),
      "Cmd" => cmd,
      "Env" => env |> env() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end),
      "WorkingDir" => cd,
      "User" => "1000:1000",
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => binds,
        "Tmpfs" => tmpfs,
        "OomScoreAdj" => 500,
        "Init" => true,
        "LogConfig" => %{"Type" => "json-file"}
      }
    }
  end

  # As Tools.run does: a crash in the wait comes back as an error, so the container is still removed.
  defp wait(id, timeout) do
    waiting =
      Task.async(fn ->
        try do
          with {:ok, _started} <- Docker.start_container(id),
               {:ok, code} <- exit_code(id),
               {:ok, output} <- Docker.container_logs(id) do
            {output, code}
          end
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(waiting, timeout) || Task.shutdown(waiting, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Polled, so a pass holds no connection to the Docker socket while it runs.
  defp exit_code(id) do
    case Docker.inspect_container(id) do
      {:ok, %{"State" => %{"Status" => "exited", "ExitCode" => code}}} ->
        {:ok, code}

      {:ok, %{"State" => %{"Status" => status}}} when status in ["created", "running", "restarting"] ->
        Process.sleep(@poll_ms)
        exit_code(id)

      {:ok, %{"State" => %{"Status" => status}}} ->
        {:error, {:container, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.PickBackend
  import Rail.Tools.Utils.RejectToken

  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend

  # How the CLI's last stream-json line reports a token Claude would not take.
  @authentication_failed ~r/"error":\s*"authentication_failed"/
  @poll_ms 1_000
  # Earlier sessions, which a pass must not read, and what later runs load, which a pass must not leave behind.
  @hidden_dirs [
    "projects",
    "sessions",
    "session-env",
    "shell-snapshots",
    "todos",
    "file-history",
    "backups",
    "agents",
    "commands",
    "skills",
    "plugins",
    "output-styles",
    "rules"
  ]
  @locked_files %{"settings.json" => "{}", "settings.local.json" => "{}", "CLAUDE.md" => ""}

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
    env = Map.merge(backend_env(backend), Keyword.get(opts, :env, %{}))

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
    config_dir = Backend.config_dir(backend)
    writable = Enum.uniq([cd, config_dir | Keyword.get(opts, :mounts, [])]) -- read_only
    locked = Enum.map(Map.keys(@locked_files), &Path.join(config_dir, &1))

    # A container whose caller is gone stops on its own at the same limit.
    cmd =
      if is_integer(timeout),
        do: ["timeout", "-k", "5", "#{div(timeout, 1000)}", backend.executable_path | argv],
        else: [backend.executable_path | argv]

    body = %{
      "Image" => Rail.sandbox_image(),
      "Cmd" => cmd,
      "Env" => env |> env() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end),
      "WorkingDir" => cd,
      "User" => "1000:1000",
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => Enum.map(writable, &"#{&1}:#{&1}") ++ Enum.map(read_only ++ locked, &"#{&1}:#{&1}:ro"),
        "Tmpfs" => Map.new(@hidden_dirs, &{Path.join(config_dir, &1), "uid=1000,gid=1000,mode=0700"}),
        "OomScoreAdj" => 500,
        "Init" => true,
        "LogConfig" => %{"Type" => "json-file"}
      }
    }

    # Docker would create a missing folder, owned by root.
    with nil <- Enum.find(writable ++ read_only, &(not File.dir?(&1))),
         _prepared = prepare_login(config_dir),
         {:ok, %{"Id" => id}} <- Docker.create_agent_container(body) do
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

  # Docker mounts over these, and would make a missing one as root, which later runs on the account could not write.
  defp prepare_login(config_dir) do
    Enum.each(@hidden_dirs, &File.mkdir_p!(Path.join(config_dir, &1)))

    Enum.each(@locked_files, fn {name, empty} ->
      case File.write(Path.join(config_dir, name), empty, [:exclusive]) do
        :ok -> :ok
        {:error, :eexist} -> :ok
      end
    end)
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

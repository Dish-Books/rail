defmodule Rail.Tools.Actions.SpawnOsProcess do
  @moduledoc false

  import Rail.Tools.Utils.Env

  @shell "/bin/sh"
  @stdout_var "__RAIL_TOOL_STDOUT"
  @stderr_var "__RAIL_TOOL_STDERR"
  @stdin_var "__RAIL_TOOL_STDIN"

  # stdin is redirected last, so a stdin file that cannot be opened says so in the
  # stderr file rather than on the BEAM's own stderr.
  @script ~s(trap "" HUP INT; exec "$0" "$@" >>"$#{@stdout_var}" 2>>"$#{@stderr_var}" <"$#{@stdin_var}")

  @doc """
  Spawns a detached child process with its output appended to files.

  The child runs under `#{@shell}` with HUP and INT trapped, so it survives the
  BEAM detaching from it. Options are `:env` (a map merged over the tool
  environment), `:cd`, `:stdout_path`, `:stderr_path` and `:stdin_path` (a file
  the child reads as its stdin; it gets `/dev/null` otherwise).

  Returns `{:ok, port, os_pid}`, `{:error, {:bad_cwd, cd}}` when `:cd` is not a
  directory, or `{:error, :no_os_pid}` when the port dies before reporting a
  PID. The caller owns the returned port and is responsible for handing it off
  with `Rail.Tools.connect_port/2`.

  The `:cd` check is up front because a port opened on a missing directory still
  hands back a PID for a child that is already dead, and writes its complaint
  straight to the BEAM's own stderr where no caller can see it.
  """
  def spawn_os_process(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    case Keyword.get(opts, :cd) do
      cd when is_binary(cd) and cd != "" ->
        if File.dir?(cd), do: open_port(executable, args, opts), else: {:error, {:bad_cwd, cd}}

      _unset ->
        open_port(executable, args, opts)
    end
  end

  defp open_port(executable, args, opts) do
    port = Port.open({:spawn_executable, @shell}, port_opts(executable, args, opts))

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        {:ok, port, os_pid}

      # coveralls-ignore-start (defensive: port died before reporting a PID)
      _other ->
        {:error, :no_os_pid}
        # coveralls-ignore-stop
    end
  end

  defp port_opts(executable, args, opts) do
    base = [
      :binary,
      :exit_status,
      args: ["-c", @script, executable | args],
      env: env_list(opts)
    ]

    case Keyword.get(opts, :cd) do
      cd when is_binary(cd) and cd != "" ->
        [{:cd, cd} | base]

      _other ->
        base
    end
  end

  defp env_list(opts) do
    opts
    |> Keyword.get(:env, %{})
    |> Map.new()
    |> Map.put(@stdout_var, Keyword.get(opts, :stdout_path, "/dev/null"))
    |> Map.put(@stderr_var, Keyword.get(opts, :stderr_path, "/dev/null"))
    |> Map.put(@stdin_var, Keyword.get(opts, :stdin_path, "/dev/null"))
    |> env()
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end
end

defmodule Rail.Tools.Utils.RedirectedCommand do
  @moduledoc false

  @shell "/bin/sh"
  @stdout_var "__RAIL_TOOL_STDOUT"
  @stderr_var "__RAIL_TOOL_STDERR"
  @stdin_var "__RAIL_TOOL_STDIN"

  # stdin is redirected last, so a stdin file that cannot be opened says so in the
  # stderr file rather than on the BEAM's own stderr.
  @script ~s(trap "" HUP INT; exec "$0" "$@" >>"$#{@stdout_var}" 2>>"$#{@stderr_var}" <"$#{@stdin_var}")

  @doc """
  The shell, its arguments and its environment for running `executable` with its
  output appended to files, whether beside Rail or in a sandbox.

  HUP and INT are trapped so the child outlives whatever started it. Options are
  `:env` (a map), `:stdout_path`, `:stderr_path` and `:stdin_path`, each file
  `/dev/null` when not given. Returns `{shell, args, env}`.
  """
  def redirected_command(executable, args, opts) when is_binary(executable) and is_list(args) do
    env =
      opts
      |> Keyword.get(:env, %{})
      |> Map.new()
      |> Map.put(@stdout_var, Keyword.get(opts, :stdout_path) || "/dev/null")
      |> Map.put(@stderr_var, Keyword.get(opts, :stderr_path) || "/dev/null")
      |> Map.put(@stdin_var, Keyword.get(opts, :stdin_path) || "/dev/null")

    {@shell, ["-c", @script, executable | args], env}
  end
end

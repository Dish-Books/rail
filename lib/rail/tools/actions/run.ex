defmodule Rail.Tools.Actions.Run do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Runs an external tool with the resolved executable and merged environment.

  Accepts `:env`, `:cd` (or `:working_directory`), `:into` and
  `:stderr_to_stdout`; returns `System.cmd/3`'s `{output, exit_code}`.

  A `:cd` that is not a directory is reported as a failed run rather than handed
  to the port, which would otherwise write its complaint straight to the BEAM's
  own stderr where no caller can see it.
  """
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cd = Keyword.get(opts, :cd) || Keyword.get(opts, :working_directory)

    if is_binary(cd) and not File.dir?(cd) do
      {"spawn: Could not cd to #{cd}\n", 1}
    else
      cmd(executable, args, opts, cd)
    end
  end

  defp cmd(executable, args, opts, cd) do
    merged_env = Tools.env(Keyword.get(opts, :env, %{}))

    base_opts = [{:env, Map.to_list(merged_env)} | Keyword.take(opts, [:into, :stderr_to_stdout])]

    cmd_opts =
      if is_binary(cd) do
        [{:cd, cd} | base_opts]
      else
        base_opts
      end

    System.cmd(Tools.resolve(executable), args, cmd_opts)
  end
end

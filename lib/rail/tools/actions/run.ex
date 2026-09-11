defmodule Rail.Tools.Actions.Run do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Runs an external tool with the resolved executable and merged environment.

  Accepts `:env`, `:cd` (or `:working_directory`), `:into` and
  `:stderr_to_stdout`; returns `System.cmd/3`'s `{output, exit_code}`.
  """
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    merged_env = Tools.env(Keyword.get(opts, :env, %{}))
    cd = Keyword.get(opts, :cd) || Keyword.get(opts, :working_directory)

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

defmodule Rail.Tools.Actions.Run do
  @moduledoc false

  import Rail.Tools.Utils.Env

  alias Rail.Tools

  @doc """
  Runs an external tool with the resolved executable and merged environment.

  Accepts `:env`, `:cd` (or `:working_directory`), `:into`, `:stderr_to_stdout`
  and `:timeout`; returns `System.cmd/3`'s `{output, exit_code}`.

  A `:cd` that is not a directory is reported as a failed run rather than handed
  to the port, which would otherwise write its complaint straight to the BEAM's
  own stderr where no caller can see it.

  `:timeout` is in milliseconds and buys the caller two things a bare
  `System.cmd/3` cannot give: a tool that wedges is killed rather than blocking
  forever, and one that cannot be spawned at all comes back as `{:error,
  reason}` instead of raising. Both make the result `{output, exit_code} |
  {:error, reason}`, so only pass a timeout if you handle the error tuple.
  """
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cd = Keyword.get(opts, :cd) || Keyword.get(opts, :working_directory)

    cond do
      is_binary(cd) and not File.dir?(cd) -> {"spawn: Could not cd to #{cd}\n", 1}
      Keyword.has_key?(opts, :timeout) -> run_until_timeout(executable, args, opts, cd)
      true -> cmd(executable, args, opts, cd)
    end
  end

  defp run_until_timeout(executable, args, opts, cd) do
    task =
      Task.async(fn ->
        try do
          cmd(executable, args, opts, cd)
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(task, Keyword.fetch!(opts, :timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp cmd(executable, args, opts, cd) do
    {path, args, env} = Tools.build_command(executable, args, Keyword.put(opts, :cd, cd))
    base_opts = [{:env, env_list(env, nil)} | Keyword.take(opts, [:into, :stderr_to_stdout])]
    cmd_opts = if is_binary(cd), do: [{:cd, cd} | base_opts], else: base_opts

    System.cmd(path, args, cmd_opts)
  end
end

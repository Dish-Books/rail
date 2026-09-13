defmodule Rail.Tools.Actions.Run do
  @moduledoc false

  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.MergedPath

  @separator ":"
  @cache_term {__MODULE__, :resolved}

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
    merged_env = env(Keyword.get(opts, :env, %{}))

    base_opts = [{:env, Map.to_list(merged_env)} | Keyword.take(opts, [:into, :stderr_to_stdout])]

    cmd_opts =
      if is_binary(cd) do
        [{:cd, cd} | base_opts]
      else
        base_opts
      end

    System.cmd(resolve(executable), args, cmd_opts)
  end

  # Resolves an executable to its absolute path on the tool PATH. Names that
  # already contain a `/` are taken as given, and a name nothing on PATH matches
  # is handed to System.cmd bare, to fail there with its own error.
  defp resolve(executable) do
    if String.contains?(executable, "/") do
      executable
    else
      resolve_once(merged_path(), executable)
    end
  end

  # Lookups are memoized node-wide, keyed by the PATH they were resolved
  # against so a changed PATH never returns a stale hit.
  defp resolve_once(path, executable) do
    cache = :persistent_term.get(@cache_term, %{})
    key = {path, executable}

    case Map.fetch(cache, key) do
      {:ok, resolved} ->
        resolved

      :error ->
        resolved = scan(path, executable)
        :persistent_term.put(@cache_term, Map.put(cache, key, resolved))
        resolved
    end
  end

  defp scan(path, executable) do
    path
    |> String.split(@separator)
    |> Enum.find_value(executable, fn dir ->
      candidate = Path.join(dir, executable)
      if executable?(candidate), do: candidate
    end)
  end

  defp executable?(candidate) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end
end

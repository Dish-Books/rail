defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @doc """
  Runs `backend`'s CLI with `argv` and waits for it, for work that has no run to
  follow, such as a triage pass.

  Takes `:env` (merged over the backend's own), `:cd`, `:timeout` and `:into`.
  Returns `{:ok, output}`, `{:error, {:exit, code}}`, `{:error, :timeout}`, or
  `{:error, :dispatch_disabled}` under the same gate as `start_os_process/2`.
  """
  def run_agent(%Backend{} = backend, argv, opts) when is_list(argv) do
    if Application.get_env(:rail, :no_dispatch, false) do
      {:error, :dispatch_disabled}
    else
      env = Map.merge(backend_env(backend), Keyword.get(opts, :env, %{}))
      run_opts = [env: env, stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :timeout, :into])

      case Tools.run(backend.executable_path, argv, run_opts) do
        {output, 0} -> {:ok, output}
        {_output, code} when is_integer(code) -> {:error, {:exit, code}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

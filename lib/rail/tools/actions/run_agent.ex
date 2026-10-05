defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.RejectToken

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  # How the CLI's last stream-json line reports a token Claude would not take.
  @authentication_failed ~r/"error":\s*"authentication_failed"/

  @doc """
  Runs `backend`'s CLI with `argv` and waits for it, for work that has no run to
  follow, such as a triage pass.

  Takes `:env` (merged over the backend's own), `:cd`, `:timeout` and `:into`.
  Returns `{:ok, output}`, `{:error, {:exit, code, output}}`, `{:error, :timeout}`,
  `{:error, :dispatch_disabled}` under the same gate as `start_os_process/2`, or
  `{:error, :backend_signed_out}` without running a CLI that could only fail.
  """
  def run_agent(%Backend{} = backend, argv, opts) when is_list(argv) do
    cond do
      Application.get_env(:rail, :no_dispatch, false) ->
        {:error, :dispatch_disabled}

      backend.status == :signed_out ->
        {:error, :backend_signed_out}

      true ->
        env = Map.merge(backend_env(backend), Keyword.get(opts, :env, %{}))
        run_opts = [env: env, stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :timeout, :into])

        case Tools.run(backend.executable_path, argv, run_opts) do
          {output, 0} ->
            {:ok, output}

          {output, code} when is_integer(code) ->
            if output =~ @authentication_failed, do: reject_token(backend)
            {:error, {:exit, code, output}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end

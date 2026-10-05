defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.PickBackend
  import Rail.Tools.Utils.RejectToken

  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  # How the CLI's last stream-json line reports a token Claude would not take.
  @authentication_failed ~r/"error":\s*"authentication_failed"/

  @doc """
  Runs `role`'s CLI with `argv` and waits for it, for work that has no run to
  follow, such as a triage pass. It runs on the account a new conversation of
  the role would, picked by the same rules, so a signed-out account never runs.
  A pass whose only accounts are signed out does not start, rather than wait.

  Takes `:env` (merged over the account's own), `:cd`, `:timeout` and `:into`.
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

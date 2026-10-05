defmodule Rail.Tools.Actions.RunAgent do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.PickBackend

  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @doc """
  Runs `role`'s CLI with `argv` and waits for it, for work that has no run to
  follow, such as a triage pass. It runs on the account a new conversation of
  the role would, picked by the same rules.

  Takes `:env` (merged over the account's own), `:cd`, `:timeout` and `:into`.
  Returns `{:ok, output}`, `{:error, {:exit, code}}`, `{:error, :timeout}`,
  `{:error, {:waiting_for_usage, resets_at}}` when every account is used up, an
  error sentence when no signed-in account offers the model, or
  `{:error, :dispatch_disabled}` under the same gate as `start_os_process/2`.
  """
  def run_agent(%Role{} = role, argv, opts) when is_list(argv) do
    if Application.get_env(:rail, :no_dispatch, false) do
      {:error, :dispatch_disabled}
    else
      case pick_backend(role.cli, role.model, nil) do
        {:ok, backend} -> run(backend, argv, opts)
        {:wait, resets_at} -> {:error, {:waiting_for_usage, resets_at}}
        {:error, :no_account} -> {:error, Backend.no_account_error(role.model, role.name)}
      end
    end
  end

  defp run(%Backend{} = backend, argv, opts) do
    env = Map.merge(backend_env(backend), Keyword.get(opts, :env, %{}))
    run_opts = [env: env, stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :timeout, :into])

    case Tools.run(backend.executable_path, argv, run_opts) do
      {output, 0} -> {:ok, output}
      {_output, code} when is_integer(code) -> {:error, {:exit, code}}
      {:error, reason} -> {:error, reason}
    end
  end
end

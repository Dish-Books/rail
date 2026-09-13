defmodule Rail.Tools.Actions.LogoutBackend do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @signed_out %{
    status: :signed_out,
    account_label: nil,
    account_detail: nil,
    usage: [],
    fetched_at: nil,
    unavailable_reason: nil
  }

  @doc """
  Signs a backend out of the account in its config directory, and records it as
  signed out straight away: nothing the last probe read about that account
  still holds, and waiting on a fresh probe would leave it showing meanwhile.
  """
  def logout_backend(_scope, %Backend{} = backend) do
    case Tools.run(backend.executable_path, ["auth", "logout"], timeout: 20_000, env: backend_env(backend)) do
      {_output, 0} -> backend |> Backend.usage_changeset(@signed_out) |> Repo.update()
      {output, status} when is_integer(status) -> {:error, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end
end

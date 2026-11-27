defmodule Rail.Users.Actions.VerifySandboxAccess do
  @moduledoc """
  Checks the Cloudflare Access token a runner reaching `/sandbox/socket` through Cloudflare carries: one of a host's
  service tokens, for the sandbox socket's own application.
  """

  import Rail.Users.Utils.VerifyAccessJwt

  alias Rail.Users.Clients.CloudflareAccess

  @doc """
  Returns `:ok` for a token the team signed for the sandbox socket's application, `{:error, :invalid_assertion}` for
  any other, `{:error, :access_off}` when Access is not set up, and `{:error, {:access_unreachable, reason}}` when the
  team's keys cannot be read.
  """
  def verify_sandbox_access(assertion) when is_binary(assertion) do
    with %{team_domain: domain, aud: aud} <- Rail.sandbox_access() || {:error, :access_off},
         {:ok, keys} <- certs(domain),
         {:ok, _claims} <- verify_access_jwt(assertion, keys, "https://" <> domain, aud) do
      :ok
    else
      :error -> {:error, :invalid_assertion}
      {:error, reason} -> {:error, reason}
    end
  end

  defp certs(domain) do
    with {:error, reason} <- CloudflareAccess.certs(domain), do: {:error, {:access_unreachable, reason}}
  end
end

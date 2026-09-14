defmodule Rail.Mcp.Utils.TokenExpiresAt do
  @moduledoc false

  @doc """
  When a token response's access token expires, or nil when it did not say.
  """
  def token_expires_at(%{"expires_in" => seconds}) when is_integer(seconds) do
    DateTime.shift(DateTime.utc_now(), second: seconds)
  end

  def token_expires_at(_tokens), do: nil
end

defmodule Rail.Mcp.Utils.GenerateToken do
  @moduledoc """
  Makes a split OAuth token `rail.<type>.<selector>.<verifier>`: the plaintext goes to the client, while Rail keeps the
  selector to look it up and a SHA-256 of the verifier. Both parts are unpadded base64url, which has no `.`.
  """

  @selector_bytes 16
  @verifier_bytes 32

  @doc "Returns `{plaintext, selector, verifier_hash}` for an `:access_token`, `:refresh_token` or `:authorization_code`."
  def generate_token(type) do
    selector = Base.url_encode64(:crypto.strong_rand_bytes(@selector_bytes), padding: false)
    verifier = :crypto.strong_rand_bytes(@verifier_bytes)
    plaintext = "rail.#{prefix(type)}.#{selector}.#{Base.url_encode64(verifier, padding: false)}"

    {plaintext, selector, :crypto.hash(:sha256, verifier)}
  end

  defp prefix(:access_token), do: "at"
  defp prefix(:refresh_token), do: "rt"
  defp prefix(:authorization_code), do: "ac"
end

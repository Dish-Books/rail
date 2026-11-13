defmodule Rail.Mcp.Utils.VerifyToken do
  @moduledoc false

  @doc "`:ok` when `verifier` hashes to `verifier_hash`, compared in constant time, else `:error`."
  def verify_token(verifier, verifier_hash) when is_binary(verifier) and is_binary(verifier_hash) do
    if Plug.Crypto.secure_compare(:crypto.hash(:sha256, verifier), verifier_hash), do: :ok, else: :error
  end
end

defmodule Rail.Mcp.Utils.ParseToken do
  @moduledoc """
  Splits a token `Rail.Mcp.Utils.GenerateToken` made back into its type, selector and verifier. A run token has no `.`,
  so it never parses as one.
  """

  @doc "Returns `{:ok, type, selector, verifier}`, or `:error` for anything else."
  def parse_token(plaintext) when is_binary(plaintext) do
    with ["rail", type, selector, verifier] <- String.split(plaintext, "."),
         {:ok, type} <- decode_type(type),
         {:ok, verifier} <- Base.url_decode64(verifier, padding: false) do
      {:ok, type, selector, verifier}
    else
      _not_a_token -> :error
    end
  end

  def parse_token(_not_a_string), do: :error

  defp decode_type("at"), do: {:ok, :access_token}
  defp decode_type("rt"), do: {:ok, :refresh_token}
  defp decode_type("ac"), do: {:ok, :authorization_code}
  defp decode_type(_unknown), do: :error
end

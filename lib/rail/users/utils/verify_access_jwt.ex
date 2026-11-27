defmodule Rail.Users.Utils.VerifyAccessJwt do
  @moduledoc false

  @doc """
  The claims of `assertion`, a Cloudflare Access token, when one of `keys` signed it for `issuer` and `aud` and it has
  not expired; `:error` for a forged, expired, other application's or other team's token, or a string that is none.
  """
  def verify_access_jwt(assertion, keys, issuer, aud) when is_binary(assertion) and is_list(keys) do
    now = System.os_time(:second)

    Enum.find_value(keys, :error, fn key ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], assertion) do
        {true, %JOSE.JWT{fields: %{"iss" => ^issuer, "aud" => auds, "exp" => exp} = fields}, _jws}
        when is_integer(exp) and exp > now ->
          if aud in List.wrap(auds), do: {:ok, fields}

        # A forged token, or a string that is not a token at all, which JOSE answers with an error.
        _refused ->
          nil
      end
    end)
  end
end

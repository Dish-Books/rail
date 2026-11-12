defmodule Rail.Users.Utils.OAuthAttrs do
  @moduledoc false

  @doc """
  The user attributes a GitHub sign-in carries: its id, login, name, email, avatar and tokens.
  """
  def oauth_attrs(%Ueberauth.Auth{} = auth) do
    avatar_url =
      auth.info.image ||
        (auth.extra && auth.extra.raw_info && get_in(auth.extra.raw_info, [:user, "avatar_url"]))

    credentials = auth.credentials || %Ueberauth.Auth.Credentials{}

    %{
      github_id: auth.uid && to_string(auth.uid),
      login: auth.info.nickname || auth.info.name,
      name: auth.info.name || auth.info.nickname,
      email: auth.info.email,
      avatar_url: avatar_url,
      # All three are replaced together, so a sign-in never leaves the last one's refresh token behind.
      github_token: credentials.token,
      github_refresh_token: credentials.refresh_token,
      github_token_expires_at: expires_at(credentials.expires_at)
    }
  end

  defp expires_at(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp expires_at(_never), do: nil
end

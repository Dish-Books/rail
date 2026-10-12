defmodule Rail.Users.Actions.RegisterOAuthUser do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def register_oauth_user(%Ueberauth.Auth{} = auth) do
    auth
    |> extract_oauth_attrs()
    |> do_register_oauth_user()
  end

  def register_oauth_user(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> do_register_oauth_user()
  end

  defp do_register_oauth_user(attrs) do
    Repo.transaction(fn ->
      github_id = attrs[:github_id]
      email = attrs[:email]

      existing_user =
        (is_binary(github_id) and Repo.get_by(User, github_id: github_id)) ||
          (is_binary(email) and Repo.get_by(User, email: email))

      case existing_user do
        %User{} = user ->
          update_attrs =
            if Map.has_key?(attrs, :admin) do
              attrs
            else
              Map.delete(attrs, :admin)
            end

          user
          |> User.changeset(update_attrs)
          |> Repo.update()
          |> case do
            {:ok, updated_user} -> updated_user
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _none ->
          %User{}
          |> User.changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, new_user} -> new_user
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  defp extract_oauth_attrs(%Ueberauth.Auth{} = auth) do
    avatar_url =
      auth.info.image ||
        (auth.extra && auth.extra.raw_info && get_in(auth.extra.raw_info, [:user, "avatar_url"]))

    credentials = auth.credentials || %Ueberauth.Auth.Credentials{}

    %{
      github_id: to_string(auth.uid),
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

  defp normalize_attrs(attrs) do
    github_id = Attrs.get(attrs, :github_id)

    %{
      github_id: if(is_integer(github_id), do: to_string(github_id), else: github_id),
      login: Attrs.get(attrs, :login),
      name: Attrs.get(attrs, :name),
      email: Attrs.get(attrs, :email),
      avatar_url: Attrs.get(attrs, :avatar_url),
      github_token: Attrs.get(attrs, :github_token),
      github_refresh_token: Attrs.get(attrs, :github_refresh_token),
      github_token_expires_at: Attrs.get(attrs, :github_token_expires_at),
      admin: Attrs.get(attrs, :admin)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

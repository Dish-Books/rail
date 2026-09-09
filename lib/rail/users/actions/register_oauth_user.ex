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
          |> User.oauth_changeset(update_attrs)
          |> Repo.update()
          |> case do
            {:ok, updated_user} -> updated_user
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _none ->
          is_first_user = not Repo.exists?(User)
          admin = if is_first_user, do: true, else: Map.get(attrs, :admin, false)
          insert_attrs = Map.put(attrs, :admin, admin)

          %User{}
          |> User.oauth_changeset(insert_attrs)
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

    token = auth.credentials && auth.credentials.token

    %{
      github_id: to_string(auth.uid),
      login: auth.info.nickname || auth.info.name,
      name: auth.info.name || auth.info.nickname,
      email: auth.info.email,
      avatar_url: avatar_url,
      github_token: token
    }
  end

  defp normalize_attrs(attrs) do
    github_id = attrs[:github_id] || attrs["github_id"]

    %{
      github_id: if(is_integer(github_id), do: to_string(github_id), else: github_id),
      login: attrs[:login] || attrs["login"],
      name: attrs[:name] || attrs["name"],
      email: attrs[:email] || attrs["email"],
      avatar_url: attrs[:avatar_url] || attrs["avatar_url"],
      github_token: attrs[:github_token] || attrs["github_token"],
      admin: Map.get(attrs, :admin, Map.get(attrs, "admin", nil))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

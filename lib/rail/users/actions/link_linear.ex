defmodule Rail.Users.Actions.LinkLinear do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  def link_linear(%Scope{user: %User{id: id}}, attrs), do: do_link_linear(id, attrs)
  def link_linear(%Scope{user: %{id: id}}, attrs) when is_binary(id), do: do_link_linear(id, attrs)
  def link_linear(%User{id: id}, attrs), do: do_link_linear(id, attrs)
  def link_linear(id, attrs) when is_binary(id), do: do_link_linear(id, attrs)
  def link_linear(_scope, _attrs), do: {:error, :not_authorized}

  defp do_link_linear(user_id, attrs) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        normalized = normalize_attrs(attrs)

        user
        |> User.linear_link_changeset(normalized)
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      linear_user_id: get_field(attrs, [:linear_user_id, "linear_user_id", :user_id, "user_id"]),
      linear_name: get_field(attrs, [:linear_name, "linear_name", :name, "name"]),
      linear_access_token: get_field(attrs, [:linear_access_token, "linear_access_token", :access_token, "access_token"]),
      linear_refresh_token:
        get_field(attrs, [:linear_refresh_token, "linear_refresh_token", :refresh_token, "refresh_token"]),
      linear_token_expires_at: extract_expiry(attrs)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get_field(attrs, keys) do
    Enum.find_value(keys, &Map.get(attrs, &1))
  end

  defp extract_expiry(attrs) do
    expires_at =
      get_field(attrs, [:linear_token_expires_at, "linear_token_expires_at", :expires_at, "expires_at"])

    expires_in = get_field(attrs, [:expires_in, "expires_in"])

    cond do
      is_struct(expires_at, DateTime) -> expires_at
      is_integer(expires_in) -> DateTime.shift(DateTime.utc_now(), second: expires_in)
      is_binary(expires_in) -> parse_seconds(expires_in)
      true -> nil
    end
  end

  defp parse_seconds(str) do
    case Integer.parse(str) do
      {sec, ""} -> DateTime.shift(DateTime.utc_now(), second: sec)
      _err -> nil
    end
  end
end

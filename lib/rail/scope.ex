defmodule Rail.Scope do
  @moduledoc """
  Defines the caller scope used throughout Rail.

  Implements scope without tenancy (D9): `%Rail.Scope{user: user, system: system}`.
  Actions take a scope, then a `%Project{}` or a project-owned struct.
  `users.admin` boolean gates admin settings (Projects, Users, Roles, Linear workspace settings).
  """

  defstruct user: nil,
            system: false

  @doc """
  Creates a scope for the given user map or struct.
  """
  def for_user(user) when is_map(user) do
    %__MODULE__{user: user, system: false}
  end

  def for_user(nil), do: nil

  @doc """
  Creates a system-level scope that bypasses user permission gates.
  """
  def for_system do
    %__MODULE__{user: nil, system: true}
  end

  @doc """
  Returns true if the scope has admin privileges.
  System scopes are considered admin.
  Users with `admin: true` are considered admin.
  """
  def admin?(%__MODULE__{system: true}), do: true
  def admin?(%__MODULE__{user: %{admin: true}}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc """
  Returns true if the user in scope has linked a Linear account.
  """
  def linear_linked?(%__MODULE__{user: %{linear_access_token: token}}) when is_binary(token) and token != "", do: true

  def linear_linked?(%__MODULE__{user: %{linear_linked: true}}), do: true
  def linear_linked?(_scope), do: false

  @doc """
  Helper to build a user scope.
  Supports `:admin` (boolean), `:linear_linked` (boolean), and `:user` overrides.
  """
  def user_scope(attrs \\ []) do
    admin = Keyword.get(attrs, :admin, false)
    linear_linked = Keyword.get(attrs, :linear_linked, false)

    user =
      case Keyword.get(attrs, :user) do
        %{} = u ->
          u

        nil ->
          %{
            id: UXID.generate!(prefix: "usr"),
            admin: admin,
            linear_linked: linear_linked,
            email: "user@example.com",
            name: "Test User"
          }
      end

    %__MODULE__{user: user, system: false}
  end

  @doc """
  Helper to build an in-memory user scope for tests that do not need persistence.
  """
  def temp_user_scope(attrs \\ []) do
    user_scope(attrs)
  end

  @doc """
  Helper to build a system scope.
  """
  def system_scope do
    for_system()
  end
end

defmodule Rail.Users.Actions.Can do
  @moduledoc false

  alias Rail.Scope

  @admin_actions [
    :list_users,
    :manage_users,
    :manage_projects,
    :manage_roles,
    :manage_linear_workspace,
    :users,
    :projects,
    :roles,
    :linear_workspace
  ]

  @admin_resources [
    :users,
    :roles,
    :projects,
    :linear_workspace
  ]

  def can?(%Scope{system: true}, _action), do: true
  def can?(nil, _action), do: false
  def can?(%Scope{user: nil}, _action), do: false

  def can?(%Scope{} = scope, action) when action in @admin_actions do
    Scope.admin?(scope)
  end

  def can?(%Scope{user: %{}}, _action), do: true

  def can?(%Scope{system: true}, _resource, _action), do: true
  def can?(nil, _resource, _action), do: false
  def can?(%Scope{user: nil}, _resource, _action), do: false

  def can?(%Scope{} = scope, :users, action) when action in [:view, :list, :manage] do
    Scope.admin?(scope)
  end

  def can?(%Scope{} = scope, resource, :manage) when resource in @admin_resources do
    Scope.admin?(scope)
  end

  def can?(%Scope{user: %{}}, resource, :view) when resource in [:projects, :roles] do
    true
  end

  def can?(%Scope{user: %{}}, _resource, _action), do: true
end

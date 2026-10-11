defmodule Rail.Users.Actions.Can do
  @moduledoc false

  alias Rail.Scope

  def can?(scope, _action), do: Scope.admin?(scope)
  # Merging is the tech lead's call, and being an admin does not make one.
  def can?(scope, :tasks, :merge), do: Scope.tech_lead?(scope)
  def can?(scope, _resource, _action), do: Scope.admin?(scope)
end

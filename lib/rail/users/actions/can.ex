defmodule Rail.Users.Actions.Can do
  @moduledoc false

  alias Rail.Scope

  def can?(scope, _action), do: Scope.admin?(scope)
  def can?(scope, _resource, _action), do: Scope.admin?(scope)
end

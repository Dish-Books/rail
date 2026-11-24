defmodule Rail.Users.Actions.Can do
  @moduledoc false

  alias Rail.Scope

  @tabs %{
    support: [:support],
    tester: [:testing, :issues],
    dev: [:overview, :support, :triage, :testing, :issues, :learnings, :sandboxes]
  }
  @all_tabs @tabs |> Map.values() |> List.flatten() |> Enum.uniq()

  def can?(scope, _action), do: Scope.admin?(scope)
  # Approving and merging are the tech lead's call, and being an admin does not make one.
  def can?(scope, :tasks, action) when action in [:merge, :approve], do: Scope.tech_lead?(scope)
  # A tab is the role's to open; being an admin adds Settings and nothing here.
  def can?(%Scope{system: true}, tab, :view) when tab in @all_tabs, do: true
  def can?(%Scope{user: %{role: role}}, tab, :view) when tab in @all_tabs, do: tab in Map.get(@tabs, role, [])
  def can?(_scope, tab, :view) when tab in @all_tabs, do: false
  def can?(scope, _resource, _action), do: Scope.admin?(scope)
end

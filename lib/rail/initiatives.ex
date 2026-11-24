defmodule Rail.Initiatives do
  @moduledoc """
  Context boundary for initiatives: a project's group of tickets across cycles. Writes broadcast
  `{:initiatives_changed, project_id}` on `"initiatives"`.
  """

  alias Rail.Initiatives.Actions

  defdelegate list_initiatives(scope, opts \\ []), to: Actions.ListInitiatives
  defdelegate get_initiative(scope, id, opts \\ []), to: Actions.GetInitiative
  defdelegate create_initiative(scope, project, attrs), to: Actions.CreateInitiative
  defdelegate update_initiative(scope, initiative, attrs), to: Actions.UpdateInitiative
  defdelegate delete_initiative(scope, initiative), to: Actions.DeleteInitiative
  defdelegate find_initiative(scope, project, name), to: Actions.FindInitiative
  defdelegate create_update_brief(scope, initiative), to: Actions.CreateUpdateBrief
end

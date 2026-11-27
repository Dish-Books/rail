defmodule Rail.Issues.Actions.RemoveTestingScenario do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @doc """
  Takes the scenario `scenario_id` out of the ticket's list and returns the ticket as it now reads. A scenario already
  gone is no change. Refuses as `Rail.Issues.Utils.UpdateTesting` does.
  """
  def remove_testing_scenario(%Scope{} = scope, %Issue{} = issue, scenario_id) when is_binary(scenario_id) do
    update_testing(scope, issue, fn locked ->
      Issue.testing_scenarios_changeset(locked, Enum.reject(locked.testing_scenarios, &(&1.id == scenario_id)), :tester)
    end)
  end
end

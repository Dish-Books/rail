defmodule Rail.Issues.Actions.SaveTestingScenario do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Scope

  @doc """
  Sets the result or note `attrs` names on the scenario `scenario_id`, and returns the ticket as it now reads. Refuses
  with `:not_found` for a scenario the ticket no longer has, and as `Rail.Issues.Utils.UpdateTesting` does.
  """
  def save_testing_scenario(%Scope{} = scope, %Issue{} = issue, scenario_id, attrs)
      when is_binary(scenario_id) and is_map(attrs) do
    update_testing(scope, issue, fn locked ->
      with %TestingScenario{} = scenario <-
             Enum.find(locked.testing_scenarios, &(&1.id == scenario_id)) || {:error, :not_found},
           {:ok, saved} <- scenario |> TestingScenario.result_changeset(attrs) |> Ecto.Changeset.apply_action(:update) do
        scenarios = Enum.map(locked.testing_scenarios, &if(&1.id == scenario_id, do: saved, else: &1))
        Issue.testing_scenarios_changeset(locked, scenarios, :tester)
      end
    end)
  end
end

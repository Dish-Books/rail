defmodule Rail.Issues.Actions.RemoveTestingImage do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @doc """
  Takes the picture at `url` out of the scenario `scenario_id` and returns the ticket as it now reads. The tracker
  keeps the file. Refuses as `Rail.Issues.Utils.UpdateTesting` does.
  """
  def remove_testing_image(%Scope{} = scope, %Issue{} = issue, scenario_id, url)
      when is_binary(scenario_id) and is_binary(url) do
    update_testing(scope, issue, fn locked ->
      scenarios =
        Enum.map(locked.testing_scenarios, fn scenario ->
          if scenario.id == scenario_id,
            do: %{scenario | images: Enum.reject(scenario.images, &(&1.url == url))},
            else: scenario
        end)

      Issue.testing_scenarios_changeset(locked, scenarios, :tester)
    end)
  end
end

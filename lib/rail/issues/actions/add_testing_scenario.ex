defmodule Rail.Issues.Actions.AddTestingScenario do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Scope

  @doc """
  Adds a tester's scenario at the end of the ticket's list and returns the ticket as it now reads. A blank or overlong
  text is the changeset's error. Refuses as `Rail.Issues.Utils.UpdateTesting` does.
  """
  def add_testing_scenario(%Scope{} = scope, %Issue{} = issue, title) when is_binary(title) do
    update_testing(scope, issue, fn locked ->
      case %{title: title} |> TestingScenario.tester_changeset() |> Ecto.Changeset.apply_action(:insert) do
        {:ok, scenario} ->
          Issue.testing_scenarios_changeset(locked, List.insert_at(locked.testing_scenarios, -1, scenario), :tester)

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
  end
end

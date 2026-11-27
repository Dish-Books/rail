defmodule Rail.Issues.Actions.SaveTestingPlace do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @doc """
  Saves the environment, platform or device `attrs` holds and returns the ticket as it now reads. Refuses as
  `Rail.Issues.Utils.UpdateTesting` does.
  """
  def save_testing_place(%Scope{} = scope, %Issue{} = issue, attrs) when is_map(attrs) do
    update_testing(scope, issue, &Issue.testing_place_changeset(&1, attrs))
  end
end

defmodule RailWeb.Utils.CalculateCriteriaTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.CalculateCriteria

  test "counts the list items under the acceptance criteria heading, stopping at the next heading" do
    description = """
    - Not a criterion.

    ## Acceptance criteria

    - One
    * Two
    1. Three

    ## Out of scope

    - Not this
    """

    assert calculate_criteria(description) == 3
  end

  test "is zero without the heading" do
    assert calculate_criteria("- One\n- Two\n") == 0
  end
end

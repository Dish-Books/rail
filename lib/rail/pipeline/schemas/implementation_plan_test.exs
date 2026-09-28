defmodule Rail.Pipeline.Schemas.ImplementationPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.ImplementationPlan

  test "the assumptions are the bullets under their heading, and stop at the next one" do
    content = """
    ## Implementation plan

    ### Approach

    - Not an assumption.

    ### Assumptions

    - QA writes the prose.
    * A missing pr file still replaces the placeholder.
    Some trailing prose that is not a bullet.

    ### Verification

    - Not an assumption either.
    """

    assert ImplementationPlan.assumptions(%ImplementationPlan{content: content}) == [
             "QA writes the prose.",
             "A missing pr file still replaces the placeholder."
           ]
  end

  test "takes the heading at any of the levels a plan puts it" do
    content = "# Plan\n\n#### Assumptions\n\n- One.\n\n## Next\n\n- Two.\n"

    assert ImplementationPlan.assumptions(%ImplementationPlan{content: content}) == ["One."]
  end

  test "a plan that took no assumptions has none" do
    content = "## Implementation plan\n\n### Approach\n\n- Change the client.\n"

    assert ImplementationPlan.assumptions(%ImplementationPlan{content: content}) == []
  end
end

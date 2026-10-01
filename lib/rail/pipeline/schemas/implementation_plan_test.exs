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

  test "an assumption keeps the lines indented under it, as a nested list" do
    content = """
    ### Assumptions

    - One Slack app serves Rail with Socket Mode on.
      - Admins paste the bot and app-level tokens in Settings.
      - Rail runs on one node,
        so there is one socket per workspace.

    - Slack user tokens are stored without rotation.
    """

    assert ImplementationPlan.assumptions(%ImplementationPlan{content: content}) == [
             "One Slack app serves Rail with Socket Mode on.\n  - Admins paste the bot and app-level tokens in Settings.\n  - Rail runs on one node,\n    so there is one socket per workspace.",
             "Slack user tokens are stored without rotation."
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

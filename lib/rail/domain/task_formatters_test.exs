defmodule Rail.Domain.TaskFormattersTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskFormatters

  test "delegates all formatting functions to Formatters" do
    task = %{
      title: "Implement Task",
      description: "Ticket text\n\n## Implementation plan\nStep 1",
      stage: :engineer,
      stage_state: :running,
      rework_cycles: 1,
      rework_budget_base: 0
    }

    assert TaskFormatters.stage_label(task) == "Engineer running · rework 1 of 5"
    assert TaskFormatters.stage_state_icon(task) == "pi-play-circle"
    assert TaskFormatters.stage_state_color(task) == :primary
    assert TaskFormatters.stage_state_color_class(task, :text) =~ "text-blue-600 dark:text-blue-500"
    refute TaskFormatters.shows_as_conflicted?(task)
    refute TaskFormatters.has_merge_conflicts?(task)
    refute TaskFormatters.uses_design?(task)
    assert TaskFormatters.ticket_for(task) == "Ticket text"
    assert TaskFormatters.plan_for(task) == "## Implementation plan\nStep 1"
  end
end

defmodule RailWeb.Components.LearningStatusTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Learnings.Schemas.Learning
  alias RailWeb.Components.LearningStatus

  test "a rule's status is one label, Flagged while an override waits, with Auto for a rule nobody approved" do
    label = fn learning, flagged ->
      render_component(&LearningStatus.learning_status/1, learning: learning, flagged: flagged)
    end

    assert label.(%Learning{status: :active}, true) =~ "Flagged"
    assert label.(%Learning{status: :active}, false) =~ "Active"
    assert label.(%Learning{status: :provisional}, false) =~ "Provisional"
    assert label.(%Learning{status: :retired}, true) =~ "Retired"
    assert label.(%Learning{status: :proposed}, false) =~ "Proposed"
    assert label.(%Learning{status: :active, auto: true}, false) =~ "Auto"
    refute label.(%Learning{status: :active, auto: false}, false) =~ "Auto"
  end
end

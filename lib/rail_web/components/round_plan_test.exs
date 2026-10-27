defmodule RailWeb.Components.RoundPlanTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Round
  alias RailWeb.Components.RoundPlan

  test "a plan that changed nothing of the ticket reads as the plan alone" do
    html = render_component(&RoundPlan.round_plan/1, round: %Round{number: 2, plan: "### What changes\n\nGuard it."})

    assert html =~ "Guard it."
    refute html =~ "round-plan-changes"
  end

  test "a round with no plan of its own says so" do
    assert render_component(&RoundPlan.round_plan/1, round: nil) =~ "This round has no plan of its own."
  end
end

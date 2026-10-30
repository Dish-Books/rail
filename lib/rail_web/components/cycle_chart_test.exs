defmodule RailWeb.Components.CycleChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.CycleChart

  setup do
    %{
      cycle: %{
        starts_on: ~D[2026-10-26],
        ends_on: ~D[2026-11-08],
        status: :running,
        scope_history: [51.0, 54.4, 56.0, 57.0],
        started_history: [4.0, 9.0, 15.0, 20.0],
        completed_history: [2.0, 8.0, 15.0, 23.0]
      }
    }
  end

  test "draws each day with a title reading its values in whole points, and a rule on today", %{cycle: cycle} do
    html = render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 12", today: ~D[2026-10-29])

    assert html =~ ~s(aria-label="Cycle 12: scope 57 points, started 20, completed 23")
    assert html =~ "<title>Day 1: scope 51, started 4, completed 2</title>"
    assert html =~ "<title>Day 2: scope 54, started 9, completed 8</title>"
    refute html =~ "Day 5:"
    assert html =~ ~s(id="cycle-chart-today")
    assert html =~ ~s(opacity="0.5")
    assert html =~ "Oct 26"
    assert html =~ "Nov 1"
    assert html =~ "Nov 8"
  end

  test "an ended cycle has no rule on today and nothing past its last day", %{cycle: cycle} do
    full = 1..14 |> Enum.to_list() |> Enum.map(&(&1 * 1.0))
    ended = %{cycle | status: :ended, scope_history: full, started_history: full, completed_history: full}

    html = render_component(&CycleChart.cycle_chart/1, cycle: ended, label: "Cycle 11", today: ~D[2026-11-20])

    refute html =~ ~s(id="cycle-chart-today")
    refute html =~ ~s(opacity="0.5")
    assert html =~ "Day 14:"
  end

  test "a one-day cycle with no started or completed history still draws its scope" do
    cycle = %{
      starts_on: ~D[2026-10-26],
      ends_on: ~D[2026-10-26],
      status: :running,
      scope_history: [0.0],
      started_history: [],
      completed_history: []
    }

    html = render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 1", today: ~D[2026-10-26])

    assert html =~ "scope 0 points, started 0, completed 0"
    assert html =~ "Day 1: scope 0, started 0, completed 0"
    refute html =~ "<circle"
  end
end

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
        started_history: [6.0, 17.0, 30.0, 43.0],
        completed_history: [2.0, 8.0, 15.0, 23.0]
      }
    }
  end

  test "draws a rule on today, with a hidden marker and the figures of each day it is given", %{cycle: cycle} do
    days = [%{"data-scope" => 51, "data-date" => "Mon Oct 26"}, %{"data-scope" => 54, "data-date" => "Tue Oct 27"}]

    html = render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 12", today: ~D[2026-10-29], days: days)
    doc = Floki.parse_fragment!(html)

    assert html =~ ~s(aria-label="Cycle 12: scope 57 points, started 43, completed 23")
    assert html =~ ~s(id="cycle-chart-today")
    assert html =~ ~s(opacity="0.5")
    assert html =~ "Oct 26"
    assert html =~ "Nov 1"
    assert html =~ "Nov 8"
    refute html =~ "<title>"

    assert ["0", "1"] = Floki.attribute(doc, "rect[data-day]", "data-day")
    assert ["Mon Oct 26", "Tue Oct 27"] = Floki.attribute(doc, "rect[data-day]", "data-date")
    assert ["0", "1"] = Floki.attribute(doc, "g[data-marker]", "data-marker")
    assert ["hidden", "hidden"] = Floki.attribute(doc, "g[data-marker]", "class")
    # One day wide, and the first starts where the chart does rather than a half step before it.
    assert ["4.0", "16.0"] = Floki.attribute(doc, "rect[data-day]", "x")
    assert ["12.0", "24.0"] = Floki.attribute(doc, "rect[data-day]", "width")
    assert ["0"] = doc |> Floki.find("svg[role=img]") |> Floki.attribute("tabindex")
    assert [class] = doc |> Floki.find("svg[role=img]") |> Floki.attribute("class")
    assert "touch-pan-y" in String.split(class)
    assert length(Floki.find(doc, "g[data-marker='0'] circle")) == 3
  end

  test "with no days to read it has no day rects and takes no focus", %{cycle: cycle} do
    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: cycle, label: "Cycle 12", today: ~D[2026-10-29])
      |> Floki.parse_fragment!()

    assert [] = Floki.find(doc, "[data-day]")
    assert [] = Floki.find(doc, "[data-marker]")
    assert [] = doc |> Floki.find("svg[role=img]") |> Floki.attribute("tabindex")
  end

  test "a marker has a dot only for the lines that reach its day", %{cycle: cycle} do
    short = %{cycle | started_history: [6.0], completed_history: []}
    days = [%{}, %{}]

    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: short, label: "Cycle 12", today: ~D[2026-10-29], days: days)
      |> Floki.parse_fragment!()

    assert length(Floki.find(doc, "g[data-marker='0'] circle")) == 2
    assert length(Floki.find(doc, "g[data-marker='1'] circle")) == 1
  end

  test "the target rises from 0 on weekdays only, reaching the latest scope by the last Saturday, with weekends hatched" do
    # A Monday to the Sunday four weeks on.
    cycle = %{
      starts_on: ~D[2026-10-26],
      ends_on: ~D[2026-11-22],
      status: :running,
      scope_history: [100.0, 120.0],
      started_history: [0.0, 0.0],
      completed_history: [0.0, 0.0]
    }

    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: cycle, label: "Cycle 14", today: ~D[2026-10-27])
      |> Floki.parse_fragment!()

    [path] = Floki.attribute(doc, "path[data-line=target]", "d")
    ys = ~r/,([\d.]+)/ |> Regex.scan(path, capture: :all_but_first) |> List.flatten()
    full = 128 - 120 / (120 * 1.1) * 120
    y = fn index -> ys |> Enum.at(index) |> String.to_float() end

    assert length(ys) == 28
    assert y.(0) == 128.0
    assert ["7 4"] = Floki.attribute(doc, "path[data-line=target]", "stroke-dasharray")

    # Friday rises to Saturday, then it holds to Monday, and again on the last weekend.
    assert y.(5) < y.(4)
    assert y.(5) == y.(6)
    assert y.(6) == y.(7)
    assert y.(8) < y.(7)
    assert y.(26) == y.(27)
    assert_in_delta y.(26), full, 0.1

    assert ["61.8", "142.7", "223.6", "304.4"] = Floki.attribute(doc, "rect[fill='url(#cycle-hatch)']", "x")
    assert ["23.1", "23.1", "23.1", "11.6"] = Floki.attribute(doc, "rect[fill='url(#cycle-hatch)']", "width")
    assert doc |> Floki.find("#cycle-chart-legend") |> Floki.text() =~ "Target"
    assert doc |> Floki.find("#cycle-chart-legend") |> Floki.text() =~ "Weekend"
  end

  test "a cycle opening on a Sunday hatches that day, and one closing on a Saturday draws no empty band" do
    cycle = %{
      starts_on: ~D[2026-11-01],
      ends_on: ~D[2026-11-07],
      status: :ended,
      scope_history: [6.0],
      started_history: [],
      completed_history: []
    }

    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: cycle, label: "Cycle 15", today: ~D[2026-11-20])
      |> Floki.parse_fragment!()

    assert ["4.0"] = Floki.attribute(doc, "rect[fill='url(#cycle-hatch)']", "x")
    assert ["52.0"] = Floki.attribute(doc, "rect[fill='url(#cycle-hatch)']", "width")
  end

  test "the hatch takes the prefix, so a closed panel beside it cannot take the pattern away", %{cycle: cycle} do
    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: cycle, label: "Cycle 12", today: ~D[2026-10-29], id_prefix: "cycle-RAIL")
      |> Floki.parse_fragment!()

    assert [_pattern] = Floki.find(doc, "pattern#cycle-RAIL-hatch")
    assert [_band | _rest] = Floki.find(doc, "rect[fill='url(#cycle-RAIL-hatch)']")
    assert [_legend] = Floki.find(doc, "#cycle-RAIL-chart-legend")
  end

  test "its ids take a prefix, so two charts on one page do not share one", %{cycle: cycle} do
    html =
      render_component(&CycleChart.cycle_chart/1,
        cycle: cycle,
        label: "Cycle 12",
        today: ~D[2026-10-29],
        id_prefix: "cycle-RAIL"
      )

    assert html =~ ~s(id="cycle-RAIL-chart")
    assert html =~ ~s(id="cycle-RAIL-chart-today")
    refute html =~ ~s(id="cycle-chart")
  end

  test "an ended cycle has no rule on today and nothing past its last day", %{cycle: cycle} do
    full = 1..14 |> Enum.to_list() |> Enum.map(&(&1 * 1.0))
    ended = %{cycle | status: :ended, scope_history: full, started_history: full, completed_history: full}

    html = render_component(&CycleChart.cycle_chart/1, cycle: ended, label: "Cycle 11", today: ~D[2026-11-20])

    refute html =~ ~s(id="cycle-chart-today")
    refute html =~ ~s(opacity="0.5")
    assert html =~ ~s(data-line="target")
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

    html = render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 1", today: ~D[2026-10-26], days: [%{}])
    doc = Floki.parse_fragment!(html)

    assert html =~ "scope 0 points, started 0, completed 0"
    assert length(Floki.find(doc, "g[data-marker='0'] circle")) == 1
    assert ["4.0"] = Floki.attribute(doc, "rect[data-day]", "x")
    assert ["312.0"] = Floki.attribute(doc, "rect[data-day]", "width")
  end

  test "a cycle with no weekday to rise across has no target and no legend" do
    cycle = %{
      starts_on: ~D[2026-11-01],
      ends_on: ~D[2026-11-01],
      status: :running,
      scope_history: [9.0],
      started_history: [],
      completed_history: []
    }

    html = render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 1", today: ~D[2026-11-01])

    refute html =~ ~s(data-line="target")
    refute html =~ "cycle-chart-legend"
  end

  test "a two-day cycle over a weekend has no target, and its legend names only the weekend" do
    cycle = %{
      starts_on: ~D[2026-10-31],
      ends_on: ~D[2026-11-01],
      status: :ended,
      scope_history: [9.0, 9.0],
      started_history: [],
      completed_history: []
    }

    doc =
      (&CycleChart.cycle_chart/1)
      |> render_component(cycle: cycle, label: "Cycle 1", today: ~D[2026-11-20])
      |> Floki.parse_fragment!()

    assert [] = Floki.find(doc, "path[data-line=target]")
    assert doc |> Floki.find("#cycle-chart-legend") |> Floki.text() =~ "Weekend"
    refute doc |> Floki.find("#cycle-chart-legend") |> Floki.text() =~ "Target"
  end

  test "no scope history at all still draws, with a target at nothing" do
    cycle = %{
      starts_on: ~D[2026-10-26],
      ends_on: ~D[2026-10-30],
      status: :running,
      scope_history: [],
      started_history: [],
      completed_history: []
    }

    assert render_component(&CycleChart.cycle_chart/1, cycle: cycle, label: "Cycle 1", today: ~D[2026-10-26]) =~
             ~s(data-line="target")
  end
end

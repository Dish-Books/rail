defmodule RailWeb.Components.CyclePanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.CyclePanel

  setup do
    cycle = %{
      id: "cyc_12",
      number: 12,
      name: nil,
      starts_on: ~D[2026-10-26],
      ends_on: ~D[2026-11-08],
      status: :running,
      scope_history: [51.0, 57.0],
      started_history: [6.0, 43.0],
      completed_history: [2.0, 23.0]
    }

    progress = %{
      scope: 57,
      started: 43,
      completed: 23,
      scope_change: 12,
      owners: [
        %{user: %{id: "usr_mk", name: "Michael Kim", login: "mk", avatar_url: nil}, points: 24, completed: 15},
        %{user: %{id: "usr_al", name: nil, login: "ana", avatar_url: nil}, points: 0, completed: 0}
      ]
    }

    %{cycle: cycle, progress: progress}
  end

  test "names a running cycle with its dates and days left, its figures and its owners' shares", %{
    cycle: cycle,
    progress: progress
  } do
    html = render_component(&CyclePanel.cycle_panel/1, cycle: cycle, progress: progress, today: ~D[2026-10-29])

    assert html =~ ~s(aria-label="Cycle 12")
    assert html =~ "Current"
    assert html =~ "Oct 26 – Nov 8 · 10 days left"
    assert html =~ ~r/data-today="\+12%"[^>]*>\s*\+12%\s*<\/span>\s*<\/p>/
    refute html =~ "since"
    assert html =~ "75%"
    assert html =~ "40%"
    assert html =~ ~s(id="cycle-chart")
    assert html =~ "Michael Kim"
    assert html =~ "63%"
    assert html =~ "ana"
    refute html =~ "Clear filter"
    assert html =~ "lg:w-[380px]"
    assert html =~ ">Assignees<"
    refute html =~ "Owner"
    assert html =~ ~s(phx-hook="CycleFigures")
  end

  test "reads every day with history off the chart, today from the panel's own figures, and no day to come", %{
    cycle: cycle,
    progress: progress
  } do
    doc =
      (&CyclePanel.cycle_panel/1)
      |> render_component(
        cycle: %{cycle | scope_history: [50.0, 51.0, 57.0]},
        progress: progress,
        today: ~D[2026-10-28]
      )
      |> Floki.parse_fragment!()

    assert ["0", "1", "2"] = Floki.attribute(doc, "rect[data-day]", "data-day")

    assert ["Mon Oct 26 · day 1 of 14", "Tue Oct 27 · day 2 of 14", "Wed Oct 28 · day 3 of 14"] =
             Floki.attribute(doc, "rect[data-day]", "data-date")

    assert ["50", "51", "57"] = Floki.attribute(doc, "rect[data-day]", "data-scope")
    assert ["+0%", "+2%", "+14%"] = Floki.attribute(doc, "rect[data-day]", "data-scope-change")
    assert ["pts", "pts", "pts"] = Floki.attribute(doc, "rect[data-day]", "data-scope-unit")
    # Linear's day three says 0 started, and the panel's 43 is what today reads.
    assert ["6", "43", "43"] = Floki.attribute(doc, "rect[data-day]", "data-started")
    assert ["12%", "84%", "75%"] = Floki.attribute(doc, "rect[data-day]", "data-started-share")
    assert ["2", "23", "23"] = Floki.attribute(doc, "rect[data-day]", "data-completed")
    assert ["4%", "45%", "40%"] = Floki.attribute(doc, "rect[data-day]", "data-completed-share")

    for {field, today} <- [
          {"date", "Oct 26 – Nov 8 · 11 days left"},
          {"scope", "57"},
          {"scopeUnit", "pts"},
          {"scopeChange", "+12%"},
          {"started", "43"},
          {"startedUnit", "pts"},
          {"startedShare", "75%"},
          {"completed", "23"},
          {"completedUnit", "pts"},
          {"completedShare", "40%"}
        ] do
      assert [^today] = doc |> Floki.find("[data-field=#{field}]") |> Floki.attribute("data-today")
    end
  end

  test "an ended cycle reads its last day from history, and a day past the end is not a day", %{
    cycle: cycle,
    progress: progress
  } do
    two_days = %{cycle | status: :ended, ends_on: ~D[2026-10-27], scope_history: [51.0, 57.0, 60.0]}

    doc =
      (&CyclePanel.cycle_panel/1)
      |> render_component(cycle: two_days, progress: %{progress | scope: 99}, today: ~D[2026-10-27])
      |> Floki.parse_fragment!()

    assert ["51", "57"] = Floki.attribute(doc, "rect[data-day]", "data-scope")
    assert ["pts", "pts"] = Floki.attribute(doc, "rect[data-day]", "data-started-unit")
  end

  test "a day of one point says pt, and a cycle opening at nothing reads no change", %{cycle: cycle, progress: progress} do
    doc =
      (&CyclePanel.cycle_panel/1)
      |> render_component(
        cycle: %{cycle | scope_history: [+0.0, 1.0], started_history: [+0.0, 1.0], completed_history: [+0.0, 1.0]},
        progress: %{progress | scope_change: nil},
        today: ~D[2026-11-07]
      )
      |> Floki.parse_fragment!()

    assert ["pts", "pt"] = Floki.attribute(doc, "rect[data-day]", "data-scope-unit")
    assert ["pts", "pt"] = Floki.attribute(doc, "rect[data-day]", "data-completed-unit")
    assert ["", ""] = Floki.attribute(doc, "rect[data-day]", "data-scope-change")
    assert [""] = doc |> Floki.find("[data-field=scopeChange]") |> Floki.attribute("data-today")
  end

  test "a picked owner reads Clear filter and dims the others", %{cycle: cycle, progress: progress} do
    html =
      render_component(&CyclePanel.cycle_panel/1,
        cycle: %{cycle | name: "Polish"},
        progress: %{progress | scope_change: -4},
        owner: "usr_mk",
        today: ~D[2026-11-07]
      )

    assert html =~ "Polish"
    assert html =~ "1 day left"
    assert html =~ ~s(data-today="-4%")
    assert html =~ "Clear filter"
    assert html =~ ~s(aria-pressed="true")
    assert html =~ "opacity-60"
  end

  test "the last day, an ended cycle and one still to start each say so", %{cycle: cycle, progress: progress} do
    assert render_component(&CyclePanel.cycle_panel/1, cycle: cycle, progress: progress, today: ~D[2026-11-08]) =~
             "Last day"

    ended = render_component(&CyclePanel.cycle_panel/1, cycle: %{cycle | status: :ended}, progress: progress)
    assert ended =~ "Ended"
    refute ended =~ "days left"
    refute ended =~ ~s(opacity="0.5")

    next = %{cycle | status: :upcoming, starts_on: ~D[2026-11-09], ends_on: ~D[2026-11-22], scope_history: []}
    empty = %{progress | scope: 1, started: 0, completed: 0, scope_change: nil, owners: []}

    html = render_component(&CyclePanel.cycle_panel/1, cycle: next, progress: empty, today: ~D[2026-10-29])
    assert html =~ "Next"
    assert html =~ "starts in 11 days"
    assert html =~ "Planned so far"
    assert html =~ "The chart starts on Nov 9."
    refute html =~ "data-day="
    refute html =~ ~s(data-line="target")
    assert html =~ ~r/>\s*pt\s*</
    refute html =~ ~s(id="cycle-chart")
    refute html =~ ~s(id="cycle-owners")

    assert render_component(&CyclePanel.cycle_panel/1, cycle: next, progress: empty, today: ~D[2026-11-08]) =~
             "starts tomorrow"
  end

  test "with a project it opens under a header that closes it, and every id takes its prefix", %{
    cycle: cycle,
    progress: progress
  } do
    project = %{id: "prj_rail", key: "RAIL"}

    html =
      render_component(&CyclePanel.cycle_panel/1,
        cycle: cycle,
        progress: progress,
        project: project,
        id_prefix: "cycle-RAIL",
        today: ~D[2026-10-29]
      )

    assert html =~ ~s(phx-click="toggle_cycle_panel")
    assert html =~ ~s(phx-hook="CycleFigures")
    assert html =~ ~s(phx-value-project_id="prj_rail")
    assert html =~ ~s(aria-expanded="true")
    assert html =~ "RAIL"
    assert html =~ "pi-caret-up"
    refute html =~ "lg:sticky"

    ids = ~r/\sid="([^"]+)"/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

    assert Enum.sort(ids) ==
             Enum.sort([
               "cycle-RAIL-panel",
               "cycle-RAIL-panel-toggle",
               "cycle-RAIL-panel-tag",
               "cycle-RAIL-panel-dates",
               "cycle-RAIL-progress",
               "cycle-RAIL-scope",
               "cycle-RAIL-started",
               "cycle-RAIL-completed",
               "cycle-RAIL-chart",
               "cycle-RAIL-chart-today",
               "cycle-RAIL-chart-legend",
               "cycle-RAIL-hatch",
               "cycle-RAIL-owners",
               "cycle-RAIL-owner-usr_mk",
               "cycle-RAIL-owner-usr_al"
             ])
  end

  test "closed, it is one row naming the cycle, its dates and its share done", %{cycle: cycle, progress: progress} do
    html =
      render_component(&CyclePanel.cycle_panel/1,
        cycle: cycle,
        progress: progress,
        project: %{id: "prj_rail", key: "RAIL"},
        open: false,
        id_prefix: "cycle-RAIL",
        today: ~D[2026-10-29]
      )

    assert html =~ ~s(id="cycle-RAIL-panel-toggle")
    assert html =~ ~s(aria-expanded="false")
    assert html =~ "Cycle 12"
    assert html =~ "Oct 26 – Nov 8 · 10 days left"
    assert html =~ ~r/40%\s*<\/span>\s*of 57/
    assert html =~ "pi-caret-down"
    refute html =~ "cycle-RAIL-scope"
    refute html =~ "Michael Kim"
    refute html =~ "phx-hook"
  end

  test "a running cycle with no change to read says nothing of it", %{cycle: cycle, progress: progress} do
    html =
      render_component(&CyclePanel.cycle_panel/1,
        cycle: cycle,
        progress: %{progress | scope: 0, started: 0, completed: 0, scope_change: nil},
        today: ~D[2026-10-29]
      )

    refute html =~ "since"
    assert html =~ "0%"
  end
end

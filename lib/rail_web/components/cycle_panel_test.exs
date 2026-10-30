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
      started_history: [4.0, 20.0],
      completed_history: [2.0, 23.0]
    }

    progress = %{
      scope: 57,
      started: 20,
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
    assert html =~ "+12% since Oct 26"
    assert html =~ "35%"
    assert html =~ "40%"
    assert html =~ ~s(id="cycle-chart")
    assert html =~ "Michael Kim"
    assert html =~ "63%"
    assert html =~ "ana"
    refute html =~ "Clear filter"
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
    assert html =~ "-4% since Oct 26"
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
    assert html =~ ~r/>\s*pt\s*</
    refute html =~ ~s(id="cycle-chart")
    refute html =~ ~s(id="cycle-owners")

    assert render_component(&CyclePanel.cycle_panel/1, cycle: next, progress: empty, today: ~D[2026-11-08]) =~
             "starts tomorrow"
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

defmodule RailWeb.Components.CycleDatesModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Cycle
  alias RailWeb.Components.CycleDatesModal

  setup do
    cycle = %Cycle{id: "cyc_2", number: 2, starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]}
    %{cycle: cycle, entry: %{id: "cyc_2", number: 2, name: nil, status: :upcoming}}
  end

  test "names the cycle, lets an upcoming one's start move and says later cycles move with the end", %{
    cycle: cycle,
    entry: entry
  } do
    html = render_component(&CycleDatesModal.cycle_dates_modal/1, cycle: entry, changeset: Ecto.Changeset.change(cycle))

    assert html =~ "Edit Cycle 2 dates"
    assert html =~ ~r/id="cycle-dates-starts"[^>]*value="2026-11-24"/
    refute html =~ ~r/id="cycle-dates-starts"[^>]*disabled/
    assert html =~ ~r/id="cycle-dates-ends"[^>]*value="2026-12-07"/
    assert html =~ "Later cycles move by as many days as the end does."
    refute html =~ "cycle-dates-error"
    refute html =~ "A running cycle keeps its start"
  end

  test "a running cycle's start is locked, and a refused edit shows its reason once", %{cycle: cycle, entry: entry} do
    changeset =
      cycle
      |> Cycle.dates_changeset(%{"starts_on" => "2026-11-20", "ends_on" => "2026-11-10"}, ~D[2026-11-21])
      |> Map.put(:action, :update)

    html =
      render_component(&CycleDatesModal.cycle_dates_modal/1,
        cycle: %{entry | status: :running, name: "Planning sprint"},
        changeset: changeset
      )

    assert html =~ "Edit Planning sprint dates"
    assert html =~ ~r/id="cycle-dates-starts"[^>]*disabled/
    assert html =~ "A running cycle keeps its start"
    assert html =~ ~r/id="cycle-dates-error"/
    assert html =~ "An upcoming cycle cannot start before today."
    assert [_once] = Regex.scan(~r/The end must be on or after the start\./, html)
  end
end

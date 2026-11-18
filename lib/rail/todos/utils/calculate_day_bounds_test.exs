defmodule Rail.Todos.Utils.CalculateDayBoundsTest do
  use ExUnit.Case, async: true

  import Rail.Todos.Utils.CalculateDayBounds

  test "gives the zone's date for the moment and the moments of its two midnights" do
    assert {"America/Los_Angeles", ~D[2026-11-17], from, to} =
             calculate_day_bounds("America/Los_Angeles", ~U[2026-11-18 03:00:00Z])

    assert DateTime.compare(from, ~U[2026-11-17 08:00:00Z]) == :eq
    assert DateTime.compare(to, ~U[2026-11-18 08:00:00Z]) == :eq
  end

  # Cuba moves its clocks at midnight: it skips 00:00 in March and repeats it in November.
  test "starts a day whose midnight the clock skips just after the gap" do
    assert {"America/Havana", ~D[2026-03-08], from, _to} =
             calculate_day_bounds("America/Havana", ~U[2026-03-08 12:00:00Z])

    assert DateTime.compare(from, ~U[2026-03-08 05:00:00Z]) == :eq
  end

  test "starts a day whose midnight the clock repeats at the first one" do
    assert {"America/Havana", ~D[2026-10-31], _from, to} =
             calculate_day_bounds("America/Havana", ~U[2026-10-31 12:00:00Z])

    assert DateTime.compare(to, ~U[2026-11-01 04:00:00Z]) == :eq
  end

  test "reads an unknown zone, or none at all, as UTC" do
    for zone <- ["Mars/Olympus_Mons", nil] do
      assert {"Etc/UTC", ~D[2026-11-18], from, to} = calculate_day_bounds(zone, ~U[2026-11-18 03:00:00Z])
      assert DateTime.compare(from, ~U[2026-11-18 00:00:00Z]) == :eq
      assert DateTime.compare(to, ~U[2026-11-19 00:00:00Z]) == :eq
    end
  end
end

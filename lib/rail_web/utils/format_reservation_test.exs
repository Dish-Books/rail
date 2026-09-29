defmodule RailWeb.Utils.FormatReservationTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatReservation

  test "reads a reservation as CPUs and GB, one CPU in the singular" do
    assert format_reservation(%{reserved_cpus: 1, reserved_memory_gb: 2}) == "1 CPU · 2 GB"
    assert format_reservation(%{reserved_cpus: 2, reserved_memory_gb: 4}) == "2 CPUs · 4 GB"
  end
end

defmodule RailWeb.Utils.FormatReservationTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatReservation

  test "reads a reservation as CPUs, one CPU in the singular" do
    assert format_reservation(%{reserved_cpus: 1}) == "1 CPU"
    assert format_reservation(%{reserved_cpus: 2}) == "2 CPUs"
  end
end

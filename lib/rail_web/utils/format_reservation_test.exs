defmodule RailWeb.Utils.FormatReservationTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatReservation

  test "reads a reservation as CPUs, one CPU in the singular" do
    assert format_reservation(%{reserved_cpus: 1}) == "1 CPU"
    assert format_reservation(%{reserved_cpus: 2}) == "2 CPUs"
  end

  test "reads part of a CPU as a fraction, and a whole float as a whole number" do
    assert format_reservation(%{reserved_cpus: 0.5}) == "0.5 CPUs"
    assert format_reservation(%{reserved_cpus: 1.25}) == "1.25 CPUs"
    assert format_reservation(%{reserved_cpus: 1.0}) == "1 CPU"
  end
end

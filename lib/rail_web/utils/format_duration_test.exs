defmodule RailWeb.Utils.FormatDurationTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatDuration

  test "nothing to say about no duration" do
    assert format_duration(nil) == ""
  end

  test "seconds alone under a minute" do
    assert format_duration(0) == "0s"
    assert format_duration(45) == "45s"
  end

  test "minutes and seconds under an hour" do
    assert format_duration(90) == "1m 30s"
    assert format_duration(3599) == "59m 59s"
  end

  test "hours, minutes and seconds beyond that" do
    assert format_duration(3661) == "1h 1m 1s"
  end

  test "a float rounds to the nearest second" do
    assert format_duration(90.4) == "1m 30s"
  end

  test "a negative duration reads as none at all" do
    assert format_duration(-10) == "0s"
  end
end

defmodule RailWeb.Utils.FormatAgeTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatAge

  test "under a minute is less than one" do
    assert format_age(0) == "<1m"
    assert format_age(59) == "<1m"
  end

  test "minutes alone under an hour" do
    assert format_age(14 * 60 + 30) == "14m"
  end

  test "hours and minutes under a day" do
    assert format_age(2 * 3600 + 14 * 60) == "2h 14m"
  end

  test "days and hours beyond that" do
    assert format_age(2 * 86_400 + 3 * 3600 + 59) == "2d 3h"
  end

  test "a negative age reads as no time at all" do
    assert format_age(-10) == "<1m"
  end
end

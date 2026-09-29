defmodule RailWeb.Utils.FormatOrdinalTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatOrdinal

  test "names a place in line by its last digit" do
    assert format_ordinal(1) == "1st"
    assert format_ordinal(2) == "2nd"
    assert format_ordinal(3) == "3rd"
    assert format_ordinal(4) == "4th"
    assert format_ordinal(22) == "22nd"
  end

  test "names the teens with th, whatever their last digit" do
    assert format_ordinal(11) == "11th"
    assert format_ordinal(12) == "12th"
    assert format_ordinal(113) == "113th"
  end
end

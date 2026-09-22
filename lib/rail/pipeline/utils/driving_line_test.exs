defmodule Rail.Pipeline.Utils.DrivingLineTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.DrivingLine

  test "takes the namespace off a line Rail wrote" do
    assert driving_line("[browser] goto http://localhost:4000") == "goto http://localhost:4000"
    assert driving_line("[qa] check \"totals\" pass") == ~s(check "totals" pass)
    assert driving_line("[demo] say 0:04 Entering a bill") == "say 0:04 Entering a bill"
  end

  test "keeps the indent, because a step is told from an instruction by it" do
    assert driving_line("[browser]   CLICK \"Save\"") == ~s(  CLICK "Save")
  end

  test "a line Rail did not write is not one of these at all" do
    assert driving_line("[tool] Bash") == nil
    assert driving_line("I opened the page.") == nil
  end
end

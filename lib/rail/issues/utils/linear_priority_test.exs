defmodule Rail.Issues.Utils.LinearPriorityTest do
  use ExUnit.Case, async: true

  import Rail.Issues.Utils.LinearPriority

  test "numbers Rail's priorities the way Linear does, and nothing else" do
    assert linear_priority(:urgent) == 1
    assert linear_priority(:high) == 2
    assert linear_priority(:medium) == 3
    assert linear_priority(:low) == 4
    assert linear_priority(:none) == nil
    assert linear_priority(nil) == nil
  end
end

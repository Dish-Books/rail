defmodule Rail.DiffTest do
  use Rail.DataCase, async: true

  test "parse/1 delegates to UnifiedDiffParser" do
    assert Rail.Diff.parse("") == []
  end
end

defmodule Rail.Diff.DiffLineTest do
  use Rail.DataCase, async: true

  alias Rail.Diff.DiffLine

  test "new/1 delegates to Rail.Domain.Diff.DiffLine" do
    line = DiffLine.new(kind: :added, text: "test line")
    assert line.kind == :added
    assert line.text == "test line"
  end
end

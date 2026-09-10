defmodule Rail.Diff.UnifiedDiffParserTest do
  use Rail.DataCase, async: true

  alias Rail.Diff.UnifiedDiffParser

  test "parse/1 delegates to Rail.Domain.Diff.UnifiedDiffParser" do
    assert UnifiedDiffParser.parse("") == []
    assert UnifiedDiffParser.parse(nil) == []
  end
end

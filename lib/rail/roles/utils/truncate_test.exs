defmodule Rail.Roles.Utils.TruncateTest do
  use Rail.DataCase, async: true

  import Rail.Roles.Utils.Truncate

  test "returns empty string when text is nil" do
    assert truncate_head_tail(nil) == ""
  end

  test "returns text unchanged when length is less than or equal to max_chars" do
    text = "Short text under four thousand chars."
    assert truncate_head_tail(text, 4000, 2000, 2000) == text
  end

  test "returns text unchanged when omitted characters is less than or equal to zero" do
    text = String.duplicate("a", 100)
    assert truncate_head_tail(text, 50, 60, 60) == text
  end

  test "truncates long text preserving head and tail with marker" do
    head = String.duplicate("H", 10)
    middle = String.duplicate("M", 80)
    tail = String.duplicate("T", 10)
    full_text = head <> middle <> tail

    result = truncate_head_tail(full_text, 50, 10, 10)

    assert result == "#{head}\n\n[... 80 characters truncated ...]\n\n#{tail}"
  end

  test "uses defaults when optional arguments omitted" do
    text = String.duplicate("x", 5000)
    result = truncate_head_tail(text)

    expected_head = String.duplicate("x", 2000)
    expected_tail = String.duplicate("x", 2000)
    assert result == "#{expected_head}\n\n[... 1000 characters truncated ...]\n\n#{expected_tail}"
  end
end

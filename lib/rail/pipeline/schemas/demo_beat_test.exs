defmodule Rail.Pipeline.Schemas.DemoBeatTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.DemoBeat

  test "stamps a beat where a person would read it on a clock" do
    assert DemoBeat.stamp(%DemoBeat{at_ms: 0, text: "Starting"}) == "0:00"
    assert DemoBeat.stamp(%DemoBeat{at_ms: 9_400, text: "Entering a bill"}) == "0:09"
    assert DemoBeat.stamp(%DemoBeat{at_ms: 71_000, text: "Saving it"}) == "1:11"
  end

  test "stamps a bare millisecond count too, for a caption not yet a beat" do
    assert DemoBeat.stamp(605_000) == "10:05"
  end

  # A caption is read at four words a second, and the picture moves on under it,
  # so a long one is never given the seven seconds it once was.
  test "a caption's reading time is 250 ms a word, between 1.2 and 3 seconds" do
    assert DemoBeat.reading_ms(%DemoBeat{text: "Saved."}) == 1_200
    assert DemoBeat.reading_ms(%DemoBeat{text: String.duplicate("word ", 8)}) == 2_000
    assert DemoBeat.reading_ms(%DemoBeat{text: String.duplicate("word ", 12)}) == 3_000
    assert DemoBeat.reading_ms(%DemoBeat{text: String.duplicate("word ", 60)}) == 3_000
  end
end

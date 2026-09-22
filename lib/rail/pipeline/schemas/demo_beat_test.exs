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

  # A caption is only worth anything if there is time to read it, and the encode
  # keeps that much of the recording at real speed however still the page is.
  test "a caption stays up long enough to be read" do
    assert DemoBeat.reading_ms(%DemoBeat{text: "Saved."}) == 2_000
    assert DemoBeat.reading_ms(%DemoBeat{text: String.duplicate("word ", 10)}) == 3_000
    assert DemoBeat.reading_ms(%DemoBeat{text: String.duplicate("word ", 60)}) == 7_000
  end
end

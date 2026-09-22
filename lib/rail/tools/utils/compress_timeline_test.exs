defmodule Rail.Tools.Utils.CompressTimelineTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.CompressTimeline

  test "a page that keeps changing plays at the speed it changed" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 400}, %{file: "c.jpg", at_ms: 900}]

    assert {[%{hold_ms: 400}, %{hold_ms: 500}, %{hold_ms: 2_000}], []} = compress_timeline(frames, [])
  end

  # Chrome sends a frame only when the page changes, so a long gap is a stretch of
  # provably nothing - an agent thinking, a server answering.
  test "a page nothing happened on is held for two seconds, not forty" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 43_400}]

    assert {[%{file: "a.jpg", hold_ms: 2_000}, %{file: "b.jpg", hold_ms: 2_000}], []} =
             compress_timeline(frames, [])
  end

  # A caption is only worth anything if there is time to read it, and the time
  # nothing happened before it goes entirely.
  test "a caption on a still page keeps its reading time and loses the wait before it" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 20_000}]

    assert {[%{hold_ms: 4_000}, %{hold_ms: 2_000}], [0]} = compress_timeline(frames, [{1_000, 4_000}])
  end

  # Moments keep their place relative to each other: the squashed time before a
  # caption shrinks, the reading time around it does not.
  test "a caption lands where its moment went in the squeezed video" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}, %{file: "c.jpg", at_ms: 30_000}]

    assert {[%{hold_ms: 1_000}, %{hold_ms: 3_000}, %{hold_ms: 2_000}], [1_000, 2_000]} =
             compress_timeline(frames, [{1_000, 1_000}, {2_000, 2_000}])
  end

  # Two captions close together each want their reading time. The stretch they
  # share is only kept once, and the second waits for the first to be read.
  test "overlapping reading windows are kept once, and the second waits its turn" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 30_000}]

    assert {[%{hold_ms: 8_000}, %{hold_ms: 2_000}], [0, 4_000]} =
             compress_timeline(frames, [{1_000, 4_000}, {3_000, 4_000}])
  end

  # An agent narrates faster than anyone reads, and the bar under the video holds
  # one caption at a time. So the picture pauses on the frame showing when the
  # second caption was said, until the first has had its time.
  test "a caption said before the last one could be read holds the picture until it has been" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}, %{file: "c.jpg", at_ms: 2_000}]

    assert {[%{hold_ms: 1_000}, %{file: "b.jpg", hold_ms: 4_000}, %{hold_ms: 2_000}], [0, 4_000]} =
             compress_timeline(frames, [{0, 4_000}, {1_000, 2_000}])
  end

  # The pause is decided in the order the captions were said, but each one's
  # place comes back in the order it was asked about.
  test "captions come back in the order they were given, whatever order they were said in" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}]

    assert {_held, [4_000, 0]} = compress_timeline(frames, [{500, 2_000}, {0, 4_000}])
  end

  # The agent says what it saw after the page last changed, so the last caption
  # can come after the last frame. The video runs long enough to read it rather
  # than ending before it goes up.
  test "a caption said after the last frame is given the time to be read" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 10_000}]

    assert {[%{hold_ms: 2_000}, %{hold_ms: 3_000}], [2_000]} = compress_timeline(frames, [{15_000, 3_000}])
  end

  test "a caption with no reading time is placed but keeps nothing" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 20_000}]

    assert {[%{hold_ms: 2_000}, %{hold_ms: 2_000}], [1_000]} = compress_timeline(frames, [{10_000, 0}])
  end

  # Two frames in the same millisecond still each get a place in the video, or
  # ffmpeg drops one and every timing behind it shifts.
  test "frames that arrived together hold for nothing rather than something negative" do
    frames = [%{file: "a.jpg", at_ms: 120}, %{file: "b.jpg", at_ms: 120}]

    assert {[%{hold_ms: 0}, %{hold_ms: 2_000}], []} = compress_timeline(frames, [])
  end

  test "a moment outside the film lands at whichever end it is nearer" do
    frames = [%{file: "a.jpg", at_ms: 1_000}, %{file: "b.jpg", at_ms: 2_000}]

    assert {_held, [0, 3_000]} = compress_timeline(frames, [{500, 0}, {60_000, 0}])
  end
end

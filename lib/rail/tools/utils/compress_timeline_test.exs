defmodule Rail.Tools.Utils.CompressTimelineTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.CompressTimeline

  test "a page that keeps changing plays at the speed it changed, and ends a second after its last frame" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 400}, %{file: "c.jpg", at_ms: 900}]

    assert {[%{hold_ms: 400}, %{hold_ms: 500}, %{hold_ms: 1_000}], []} = compress_timeline(frames, [])
  end

  # Chrome sends a frame only when the page changes, so a long gap is a stretch of
  # provably nothing - an agent thinking, a server answering.
  test "a page nothing happened on is held for a second, not forty" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 43_400}]

    assert {[%{file: "a.jpg", hold_ms: 1_000}, %{file: "b.jpg", hold_ms: 1_000}], []} =
             compress_timeline(frames, [])
  end

  # The caption stays up in the bar under the video while the picture moves on,
  # so it is never a reason for a still frame to hold.
  test "a still frame holds no longer than a second while a caption is up" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 20_000}, %{file: "c.jpg", at_ms: 21_000}]

    assert {[%{hold_ms: 1_000}, %{hold_ms: 1_000}, %{hold_ms: 250}], [50]} =
             compress_timeline(frames, [{1_000, 1_200}])
  end

  # Moments keep their place relative to the frames around them: a caption said
  # just before a click lands just before the frame the click painted.
  test "a caption lands where its moment went in the squeezed video" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 10_000}, %{file: "c.jpg", at_ms: 10_500}]

    assert {_held, [900]} = compress_timeline(frames, [{9_000, 1_200}])
  end

  # The bar holds one caption at a time, so the picture waits on the frame showing
  # when the second caption was said, until the first has had its reading time.
  test "a caption said before the last one could be read holds the picture for the difference only" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}, %{file: "c.jpg", at_ms: 1_500}]

    assert {[%{hold_ms: 1_000}, %{file: "b.jpg", hold_ms: 1_500}, %{hold_ms: 3_500}], [0, 2_000]} =
             compress_timeline(frames, [{0, 2_000}, {1_000, 3_000}])
  end

  test "a caption said once the one before has been read holds nothing" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}, %{file: "c.jpg", at_ms: 3_000}]

    assert {[%{hold_ms: 1_000}, %{hold_ms: 1_000}, %{hold_ms: 2_200}], [0, 2_000]} =
             compress_timeline(frames, [{0, 1_200}, {3_000, 1_200}])
  end

  # The pause is decided in the order the captions were said, but each one's
  # place comes back in the order it was asked about.
  test "captions come back in the order they were given, whatever order they were said in" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_000}]

    assert {_held, [3_000, 0]} = compress_timeline(frames, [{500, 2_000}, {0, 3_000}])
  end

  # Everything filmed after the walkthrough is the run going on past it, and was
  # the long empty stretch at the end of every demo.
  test "frames long after the last caption are cut a second after its reading time" do
    frames = [
      %{file: "a.jpg", at_ms: 0},
      %{file: "b.jpg", at_ms: 500},
      %{file: "c.jpg", at_ms: 4_000},
      %{file: "d.jpg", at_ms: 9_000},
      %{file: "e.jpg", at_ms: 60_000}
    ]

    assert {[
              %{file: "a.jpg", hold_ms: 500},
              %{file: "b.jpg", hold_ms: 1_000},
              %{file: "c.jpg", hold_ms: 1_000},
              %{file: "d.jpg", hold_ms: 700}
            ], [500]} = compress_timeline(frames, [{500, 1_700}])
  end

  # The agent says what it saw after the page last changed, so the last caption
  # can come after the last frame. The video runs long enough to read it.
  test "a caption said after the last frame is given the time to be read" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 10_000}]

    assert {[%{hold_ms: 1_000}, %{hold_ms: 5_000}], [2_000]} = compress_timeline(frames, [{15_000, 3_000}])
  end

  # Two frames in the same millisecond still each get a place in the video, or
  # ffmpeg drops one and every timing behind it shifts.
  test "frames that arrived together hold for nothing rather than something negative" do
    frames = [%{file: "a.jpg", at_ms: 120}, %{file: "b.jpg", at_ms: 120}]

    assert {[%{hold_ms: 0}, %{hold_ms: 1_000}], []} = compress_timeline(frames, [])
  end

  # A caption said before anything painted lands at the start, and one said over
  # it waits on the first frame.
  test "a moment before the film lands at its start" do
    frames = [%{file: "a.jpg", at_ms: 1_000}, %{file: "b.jpg", at_ms: 2_000}]

    assert {[%{file: "a.jpg", hold_ms: 2_200}, %{file: "b.jpg", hold_ms: 1_200}], [0, 1_200]} =
             compress_timeline(frames, [{0, 1_200}, {500, 1_200}])
  end
end

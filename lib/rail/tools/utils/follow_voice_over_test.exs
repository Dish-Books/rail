defmodule Rail.Tools.Utils.FollowVoiceOverTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.FollowVoiceOver

  # The agent says the caption and then takes seconds to click. The line waits for the click, and the clicks it made
  # setting up before the first caption are not in the video.
  test "a line starts just before its beat's first action, not at its caption" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 5_100}]

    assert {[%{file: "a.jpg", hold_ms: 1_400}, %{file: "b.jpg", hold_ms: 2_400}], [1_000]} =
             follow_voice_over(frames, [{1_000, 1_000}], [200, 5_000])
  end

  test "a beat with no action starts at its caption, over the screen as it was then" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 2_000}, %{file: "c.jpg", at_ms: 9_000}]

    assert {[%{file: "b.jpg", hold_ms: 3_500}], [1_000]} = follow_voice_over(frames, [{3_000, 1_500}], [])
  end

  # A spinner paints a frame every 275 ms, so nothing about the frames says the minute was empty.
  test "a minute of spinner frames between two beats is cut to the pause, and the next line opens on the frame then" do
    spinner = for step <- 0..220, do: %{file: "spin#{step}.jpg", at_ms: 2_000 + step * 275}
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 600} | spinner]

    assert {[%{file: "a.jpg", hold_ms: 600}, %{file: "b.jpg", hold_ms: 1_600}, %{file: "spin218.jpg", hold_ms: 1_800}],
            [200, 2_200]} = follow_voice_over(frames, [{0, 1_000}, {62_100, 800}], [500])
  end

  test "a line longer than its beat holds the last kept frame only until the line and its pause end" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 1_100}, %{file: "c.jpg", at_ms: 10_300}]

    assert {[%{file: "a.jpg", hold_ms: 1_100}, %{file: "b.jpg", hold_ms: 5_900}, %{file: "c.jpg", hold_ms: 2_400}],
            [700, 6_700]} = follow_voice_over(frames, [{0, 5_000}, {10_000, 500}], [1_000, 10_200])
  end

  # Something is still happening on screen, so the line ends and the picture goes on.
  test "a beat that keeps more than its line plays on with no voice, and the next line follows straight after" do
    frames = [
      %{file: "a.jpg", at_ms: 0},
      %{file: "b.jpg", at_ms: 1_100},
      %{file: "c.jpg", at_ms: 2_100},
      %{file: "d.jpg", at_ms: 5_200}
    ]

    assert {[%{file: "a.jpg", hold_ms: 1_100}, %{file: "b.jpg", hold_ms: 1_000}, %{file: "c.jpg", hold_ms: 2_900}],
            [0, 3_500]} = follow_voice_over(frames, [{0, 500}, {5_000, 500}], [100, 1_000, 2_000])
  end

  test "the time between two actions of one beat is cut" do
    frames = [
      %{file: "a.jpg", at_ms: 0},
      %{file: "b.jpg", at_ms: 200},
      %{file: "waiting.jpg", at_ms: 2_000},
      %{file: "d.jpg", at_ms: 4_100}
    ]

    assert {[
              %{file: "a.jpg", hold_ms: 200},
              %{file: "b.jpg", hold_ms: 1_400},
              %{file: "waiting.jpg", hold_ms: 100},
              %{file: "d.jpg", hold_ms: 2_800}
            ], [0]} = follow_voice_over(frames, [{0, 3_500}], [100, 4_000])
  end

  # QA's take: after the Retry click the recorder switched user and waited, then said the next caption.
  test "an action after its line has ended, seconds after the one before, is cut" do
    frames = [
      %{file: "a.jpg", at_ms: 0},
      %{file: "retried.jpg", at_ms: 1_100},
      %{file: "switched.jpg", at_ms: 6_400},
      %{file: "signed_in.jpg", at_ms: 9_400},
      %{file: "next.jpg", at_ms: 21_000}
    ]

    assert {[
              %{file: "a.jpg", hold_ms: 1_100},
              %{file: "retried.jpg", hold_ms: 3_300},
              %{file: "next.jpg", hold_ms: 2_000}
            ], [700, 4_400]} = follow_voice_over(frames, [{0, 2_700}, {22_000, 1_000}], [1_000, 6_300, 9_300])
  end

  # A form filled field by field and then saved goes on well past its caption, and its Save is the point.
  test "a last beat whose actions follow one another keeps them past 10 s" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "saved.jpg", at_ms: 14_100}]

    assert {[%{file: "a.jpg", hold_ms: 10_400}, %{file: "saved.jpg", hold_ms: 2_400}], [1_000]} =
             follow_voice_over(frames, [{0, 1_000}], Enum.to_list(2_000..14_000//2_000))
  end

  test "a last beat whose only action comes long after its caption plays at its caption" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "settings.jpg", at_ms: 30_100}]

    assert {[%{file: "a.jpg", hold_ms: 1_500}], [0]} = follow_voice_over(frames, [{0, 500}], [30_000])
  end

  # Placed in the order said, two said in the same millisecond in the order given, and each comes back where it
  # was asked about. The video ends a second after the last line.
  test "line starts come back in the order given, ties kept in order, and the video ends a second after the last" do
    frames = [%{file: "a.jpg", at_ms: 0}]

    assert {[%{file: "a.jpg", hold_ms: 4_700}], [1_600, 0, 3_000]} =
             follow_voice_over(frames, [{1_000, 400}, {0, 600}, {1_000, 700}], [])
  end

  # The agent touching the browser well after its last caption is the run going on past the walkthrough.
  test "an action long after the last caption is not in the video" do
    frames = [%{file: "a.jpg", at_ms: 0}, %{file: "b.jpg", at_ms: 300}, %{file: "settings.jpg", at_ms: 30_100}]

    assert {[%{file: "a.jpg", hold_ms: 300}, %{file: "b.jpg", hold_ms: 2_400}], [0]} =
             follow_voice_over(frames, [{0, 500}], [200, 30_000])
  end
end

defmodule Rail.Tools.Utils.CompressTimeline do
  @moduledoc """
  Squeezes the time nothing happened out of a recording, says where each caption
  lands in what is left, and ends the video once the last caption has been read.

  Chrome only sends a frame when the page changes, so a long gap between two
  frames is a stretch of provably nothing: an agent thinking, a server
  answering, somebody reading code with the camera on a still page. So no frame
  holds longer than a second, whether a caption is up or not. A caption stays up
  in the bar under the video while the picture moves on beneath it.

  The same squashing moves the captions. One said at 1:35 of the recording
  lands wherever 1:35 went in the video, so the words still arrive with the
  thing they describe.

  The picture waits only where it has to. The bar holds one caption at a time,
  so a caption said before the one before it has been read is held back, and the
  picture waits on whatever frame it was showing for the difference and no longer.

  Everything filmed after the last caption has been read is the run going on
  past the walkthrough, so the video ends a second after that, or a second after
  the last frame when nothing was said, and a page painted well after the last
  caption is never in it.
  """

  # Long enough that a page settling is seen to settle, short enough that a
  # still one is not watched.
  @max_hold_ms 1_000

  # Long enough to see the last screen, short enough not to feel like a hang.
  @tail_ms 1_000

  # A page painted this long after the last caption is the run going on past the
  # walkthrough; one painted sooner is the result the caption announced.
  @past_walkthrough_ms 10_000

  @doc """
  Returns `{frames, video_times}` for recorded `frames` - `%{file:, at_ms:}`,
  in order - and `marks`, each `{at_ms, for_ms}` a caption said at `at_ms` and
  the time it takes to read.

  `frames` comes back with a `hold_ms` each, which is how long it is shown in
  the video, and without the frames past the video's end. `video_times` is where
  each mark begins in the video, in the order the marks were given.
  """
  def compress_timeline([_first | _rest] = frames, marks) when is_list(marks) do
    {spans, _video_ms} =
      frames
      |> walkthrough(marks)
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.map_reduce(0, fn [frame, next], video_ms ->
        span = span(frame, next, video_ms)

        {span, video_ms + span.hold_ms}
      end)

    {pauses, video_times, read_until} = readable(spans, marks)
    held = held(spans, pauses)
    end_ms = (read_until || last_start(held)) + @tail_ms

    {cut(held, end_ms), video_times}
  end

  # Squeezing a long still stretch to a second would otherwise slide a page painted
  # long after the last caption into the video's final second, under that caption.
  defp walkthrough(frames, []), do: frames

  defp walkthrough([first | rest], marks) do
    last_said = marks |> Enum.map(fn {at_ms, _for_ms} -> at_ms end) |> Enum.max()

    [first | Enum.take_while(rest, &(&1.at_ms <= last_said + @past_walkthrough_ms))]
  end

  # In the order they were said, each caption has to wait for the one before it
  # to have been read. Where it would not have, the picture pauses at the moment
  # it was said for as long as the difference, which pushes everything after it
  # along too. What comes back is those pauses, where every caption lands once
  # they are in, in the order the marks were given, and when the last is read.
  defp readable(spans, marks) do
    {pauses, _shift, read_until, placed} =
      marks
      |> Enum.with_index()
      |> Enum.sort_by(fn {{at_ms, _for_ms}, index} -> {at_ms, index} end)
      |> Enum.reduce({[], 0, nil, %{}}, fn {{at_ms, for_ms}, index}, {pauses, shift, read_until, placed} ->
        lands = video_time(spans, at_ms) + shift

        {lands, pauses, shift} =
          if is_integer(read_until) and lands < read_until,
            do: {read_until, [{at_ms, read_until - lands} | pauses], shift + read_until - lands},
            else: {lands, pauses, shift}

        {pauses, shift, lands + for_ms, Map.put(placed, index, lands)}
      end)

    {pauses, Enum.map(0..(length(marks) - 1)//1, &placed[&1]), read_until}
  end

  # A pause is the frame that was showing when the held-back caption was said,
  # shown for longer; one said before anything was painted waits on the first.
  defp held(spans, pauses) do
    Enum.reduce(pauses, spans, fn {at_ms, wait_ms}, spans ->
      index = Enum.find_index(spans, &showing?(&1, at_ms)) || 0

      List.update_at(spans, index, &%{&1 | hold_ms: &1.hold_ms + wait_ms})
    end)
  end

  defp last_start(spans), do: spans |> Enum.drop(-1) |> Enum.map(& &1.hold_ms) |> Enum.sum()

  # Every frame that starts before the end is kept, and the last of them is shown
  # until the end, whether that cuts it short or keeps it up for the last caption.
  defp cut(spans, end_ms) do
    {kept, _video_ms} =
      Enum.reduce_while(spans, {[], 0}, fn span, {kept, video_ms} ->
        if video_ms < end_ms,
          do: {:cont, {[{span, video_ms} | kept], video_ms + span.hold_ms}},
          else: {:halt, {kept, video_ms}}
      end)

    [{last, last_start} | earlier] = kept

    Enum.reduce(earlier, [%{file: last.file, at_ms: last.at_ms, hold_ms: end_ms - last_start}], fn {span, _start}, acc ->
      [Map.take(span, [:file, :at_ms, :hold_ms]) | acc]
    end)
  end

  # A frame holds as long as it was really on screen, up to a second. The last
  # one has nothing after it, so it holds the second and lets the end decide.
  defp span(frame, nil, video_ms) do
    %{file: frame.file, at_ms: frame.at_ms, to: nil, real: nil, video_ms: video_ms, hold_ms: @max_hold_ms}
  end

  defp span(frame, next, video_ms) do
    real = next.at_ms - frame.at_ms

    %{
      file: frame.file,
      at_ms: frame.at_ms,
      to: next.at_ms,
      real: real,
      video_ms: video_ms,
      hold_ms: min(real, @max_hold_ms)
    }
  end

  defp showing?(%{to: nil} = span, at_ms), do: span.at_ms <= at_ms
  defp showing?(span, at_ms), do: span.at_ms <= at_ms and at_ms < span.to

  # Within one hold, time is squashed evenly into the hold, so a moment keeps its
  # place relative to the frames around it. Before the first frame is the start.
  defp video_time(spans, at_ms) do
    case Enum.find(spans, &showing?(&1, at_ms)) do
      %{real: nil} = span -> span.video_ms + min(at_ms - span.at_ms, span.hold_ms)
      %{} = span -> round(span.video_ms + (at_ms - span.at_ms) * span.hold_ms / span.real)
      nil -> 0
    end
  end
end

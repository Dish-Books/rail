defmodule Rail.Tools.Utils.CompressTimeline do
  @moduledoc """
  Squeezes the time nothing happened out of a recording, and says where each
  caption lands in what is left.

  Chrome only sends a frame when the page changes, so a long gap between two
  frames is a stretch of provably nothing: an agent thinking, a server
  answering, somebody reading code with the camera on a still page. Played back
  at the speed it was recorded, that is dead air. So no frame holds longer than
  a couple of seconds - except where a caption has just gone up, because a
  caption is only worth anything if there is time to read it.

  Those reading windows are the marks: each one is a stretch of the recording
  that plays at real speed however still the page is. Everything else in a long
  hold is squashed to fit what is left of it, and where a caption's window
  covers all the time worth keeping, the rest goes entirely.

  The same squashing moves the captions. One said at 1:35 of the recording
  lands wherever 1:35 went in the video, so the words still arrive with the
  thing they describe.

  The opposite happens too. An agent narrates faster than anyone reads, and
  two captions said a second apart would put the second over the first before
  the first was half read - the bar under the video holds one at a time. So a
  caption that arrives while the one before it still needs reading is held
  back, and the picture waits on whatever frame it was showing until the words
  have had their time. A demo that pauses for a beat is watchable; one whose
  captions flicker past is not.
  """

  # Long enough that a page settling is seen to settle, short enough that a
  # still one is not watched.
  @max_hold_ms 2_000

  # Long enough to read the last screen, short enough not to feel like a hang.
  @tail_ms 2_000

  @doc """
  Returns `{frames, video_times}` for recorded `frames` - `%{file:, at_ms:}`,
  in order - and `marks`, each `{at_ms, for_ms}` a stretch that has to play at
  real speed.

  `frames` comes back with a `hold_ms` each, which is how long it is shown in
  the video. `video_times` is where each mark begins in the video, in the order
  the marks were given.
  """
  def compress_timeline([_first | _rest] = frames, marks) when is_list(marks) do
    kept = kept(marks)
    tail_end = Enum.reduce(kept, List.last(frames).at_ms + @tail_ms, fn {_from, to}, latest -> max(latest, to) end)

    {spans, _video_ms} =
      frames
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.map_reduce(0, fn [frame, next], video_ms ->
        to = if next, do: next.at_ms, else: tail_end
        span = span(frame, to, video_ms, kept)

        {span, video_ms + span.hold_ms}
      end)

    {pauses, video_times} = readable(spans, kept, marks)

    {spans |> held(pauses) |> Enum.map(&Map.take(&1, [:file, :at_ms, :hold_ms])), video_times}
  end

  # In the order they were said, each caption has to wait for the one before it
  # to have been read. Where it would not have, the picture pauses at the moment
  # it was said for as long as the difference, which pushes everything after it
  # along too. What comes back is those pauses and where every caption lands once
  # they are in, in the order the marks were given.
  defp readable(spans, kept, marks) do
    {pauses, _shift, _read_until, placed} =
      marks
      |> Enum.with_index()
      |> Enum.sort_by(fn {{at_ms, _for_ms}, index} -> {at_ms, index} end)
      |> Enum.reduce({[], 0, nil, %{}}, fn {{at_ms, for_ms}, index}, {pauses, shift, read_until, placed} ->
        lands = video_time(spans, kept, at_ms) + shift

        {lands, pauses, shift} =
          if is_integer(read_until) and lands < read_until,
            do: {read_until, [{at_ms, read_until - lands} | pauses], shift + read_until - lands},
            else: {lands, pauses, shift}

        {pauses, shift, lands + for_ms, Map.put(placed, index, lands)}
      end)

    {pauses, Enum.map(0..(length(marks) - 1)//1, &placed[&1])}
  end

  # A pause is the frame that was showing when the held-back caption was said,
  # shown for longer.
  defp held(spans, pauses) do
    Enum.reduce(pauses, spans, fn {at_ms, wait_ms}, spans ->
      index = Enum.find_index(spans, &(&1.at_ms <= at_ms and at_ms < &1.to)) || length(spans) - 1

      List.update_at(spans, index, &%{&1 | hold_ms: &1.hold_ms + wait_ms})
    end)
  end

  # Two captions close together each want their own reading time, and the time
  # they share is only worth keeping once.
  defp kept(marks) do
    marks
    |> Enum.filter(fn {_at_ms, for_ms} -> for_ms > 0 end)
    |> Enum.map(fn {at_ms, for_ms} -> {at_ms, at_ms + for_ms} end)
    |> Enum.sort()
    |> Enum.reduce([], fn
      {from, to}, [{kept_from, kept_to} | rest] when from <= kept_to -> [{kept_from, max(to, kept_to)} | rest]
      span, merged -> [span | merged]
    end)
    |> Enum.reverse()
  end

  # A frame holds as long as it was really on screen, capped - but never cut
  # below the reading time of any caption that was up while it was.
  defp span(frame, to, video_ms, kept) do
    real = to - frame.at_ms
    reading = overlap(kept, frame.at_ms, to)

    %{
      file: frame.file,
      at_ms: frame.at_ms,
      to: to,
      real: real,
      reading: reading,
      video_ms: video_ms,
      hold_ms: real |> min(@max_hold_ms) |> max(reading)
    }
  end

  # Within one hold, reading time plays at real speed and the rest is squashed
  # into whatever the hold has left over, so a moment keeps its place relative to
  # the captions around it.
  defp video_time(spans, kept, at_ms) do
    case Enum.find(spans, &(&1.at_ms <= at_ms and at_ms < &1.to)) || before_or_after(spans, at_ms) do
      :before ->
        0

      %{} = span ->
        at_ms = min(at_ms, span.to)
        read = overlap(kept, span.at_ms, at_ms)
        squashed = at_ms - span.at_ms - read
        ratio = if span.real > span.reading, do: (span.hold_ms - span.reading) / (span.real - span.reading), else: 0

        round(span.video_ms + read + squashed * ratio)
    end
  end

  # The recorder's clock starts on its first frame and the tail runs past every
  # caption with a reading time, so a recording never lands here. A caller that
  # hands in something outside the film gets its nearest end rather than a crash.
  defp before_or_after([first | _rest], at_ms) when at_ms < first.at_ms, do: :before
  defp before_or_after(spans, _at_ms), do: List.last(spans)

  defp overlap(kept, from, to) do
    Enum.reduce(kept, 0, fn {kept_from, kept_to}, total -> total + max(0, min(to, kept_to) - max(from, kept_from)) end)
  end
end

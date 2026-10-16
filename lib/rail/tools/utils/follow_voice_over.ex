defmodule Rail.Tools.Utils.FollowVoiceOver do
  @moduledoc """
  Times a voiced recording by its lines and the clicks, key presses, scrolls and navigations the page reported, so
  each line starts as its action lands and the recording between beats is cut however busy the page was.
  """

  # Long enough to hear the line begin before the click, short enough that it still describes it.
  @lead_ms 300

  # Long enough to see what an action did.
  @after_action_ms 1_500

  # After each line before the next, before the first, and after the last.
  @pause_ms 1_000

  # As in `CompressTimeline`: a first action this long after the last caption is the run going on past the walkthrough.
  @past_walkthrough_ms 10_000

  # Actions this close together are one beat's however long its line, as a form's fields and then its Save are.
  @chained_ms 3_000

  @doc """
  Returns `{frames, video_times}` for recorded `frames` - `%{file:, at_ms:}`, in order - `lines`, each `{at_ms,
  spoken_ms}` a caption said at `at_ms` and how long its line takes to say, and `actions`, the moments the page
  was acted on, all on the recording's clock.

  `frames` comes back as what the video shows, each with a `hold_ms`, and `video_times` is where each line starts
  in the video, in the order the lines were given.
  """
  def follow_voice_over([_first | _rest] = frames, [_said | _more] = lines, actions) when is_list(actions) do
    beats = beats(lines, Enum.sort(actions))
    %{start: first_start} = hd(beats)
    lead_in = {max(first_start - @pause_ms, 0), first_start, 0}
    nexts = beats |> tl() |> Enum.map(& &1.start) |> Kernel.++([nil])

    {pieces, {_video_ms, placed}} =
      beats
      |> Enum.zip(nexts)
      |> Enum.flat_map_reduce({span(lead_in), %{}}, fn {beat, next_start}, {video_ms, placed} ->
        pieces = pieces(beat, next_start)

        {pieces, {video_ms + Enum.sum_by(pieces, &span/1), Map.put(placed, beat.index, video_ms)}}
      end)

    shown = Enum.flat_map([lead_in | pieces], &shown(frames, &1))

    {merged(shown), Enum.map(0..(length(lines) - 1), &placed[&1])}
  end

  # In the order they were said, each beat starts its line just before its first action, never before its caption.
  defp beats(lines, actions) do
    sorted = lines |> Enum.with_index() |> Enum.sort_by(fn {{at_ms, _spoken_ms}, index} -> {at_ms, index} end)
    next_said = sorted |> tl() |> Enum.map(fn {{at_ms, _spoken_ms}, _index} -> at_ms end) |> Kernel.++([nil])

    Enum.zip_with(sorted, next_said, fn {{said, spoken_ms}, index}, next ->
      {start, acted} = acted(actions, said, next, spoken_ms)

      %{index: index, spoken_ms: spoken_ms, actions: acted, start: start, last?: is_nil(next)}
    end)
  end

  # A beat keeps the first action after its caption, then each that lands while its line and pause last or that
  # follows the one before closely. The rest before the next caption is setup for the next beat.
  defp acted(actions, said, next, spoken_ms) do
    case Enum.filter(actions, &(&1 >= said and (is_nil(next) or &1 < next))) do
      [first | _rest] when is_nil(next) and first > said + @past_walkthrough_ms ->
        {said, []}

      [first | rest] ->
        start = max(said, first - @lead_ms)
        line_ends = start + spoken_ms + @pause_ms

        kept =
          Enum.reduce_while(rest, [first], fn at_ms, [previous | _earlier] = kept ->
            if at_ms <= line_ends or at_ms - previous <= @chained_ms,
              do: {:cont, [at_ms | kept]},
              else: {:halt, kept}
          end)

        {start, Enum.reverse(kept)}

      [] ->
        {said, []}
    end
  end

  # What the beat keeps of the recording, each piece `{from, to, hold_ms}`, with the hold on the last piece for as
  # long as the line and its pause outlast what is kept. The last beat's pause comes after whichever ends later.
  defp pieces(%{actions: []} = beat, _next_start), do: [{beat.start, beat.start, held(beat, 0)}]

  defp pieces(%{actions: [first | rest]} = beat, next_start) do
    [{last_from, last_to} | earlier] =
      kept =
      Enum.reduce(rest, [{beat.start, until(first, next_start)}], fn at_ms, [{from, to} | earlier] = so_far ->
        if at_ms <= to,
          do: [{from, max(to, until(at_ms, next_start))} | earlier],
          else: [{at_ms, until(at_ms, next_start)} | so_far]
      end)

    kept_ms = Enum.sum_by(kept, fn {from, to} -> to - from end)

    Enum.reverse([{last_from, last_to, held(beat, kept_ms)} | Enum.map(earlier, fn {from, to} -> {from, to, 0} end)])
  end

  defp until(at_ms, nil), do: at_ms + @after_action_ms
  defp until(at_ms, next_start), do: min(at_ms + @after_action_ms, next_start)

  defp held(%{last?: true} = beat, kept_ms), do: max(beat.spoken_ms, kept_ms) + @pause_ms - kept_ms
  defp held(beat, kept_ms), do: max(beat.spoken_ms + @pause_ms - kept_ms, 0)

  defp span({from, to, hold_ms}), do: to - from + hold_ms

  # The frame on screen as the piece starts, then each painted inside it, each until the next or the piece's end.
  defp shown(frames, {from, to, hold_ms}) do
    showing = frames |> Enum.take_while(&(&1.at_ms <= from)) |> List.last() || hd(frames)
    painted = Enum.filter(frames, &(&1.at_ms > from and &1.at_ms < to))
    bounds = Enum.chunk_every([from | Enum.map(painted, & &1.at_ms)], 2, 1, [to])

    [showing | painted]
    |> Enum.zip_with(bounds, fn frame, [start, finish] ->
      %{file: frame.file, at_ms: frame.at_ms, hold_ms: finish - start}
    end)
    |> List.update_at(-1, &%{&1 | hold_ms: &1.hold_ms + hold_ms})
  end

  # A cut that lands on the frame already showing is one longer hold, and a frame shown for nothing is not shown.
  defp merged(shown) do
    shown
    |> Enum.reject(&(&1.hold_ms == 0))
    |> Enum.chunk_by(& &1.file)
    |> Enum.map(fn [first | _same] = run -> %{first | hold_ms: Enum.sum_by(run, & &1.hold_ms)} end)
  end
end

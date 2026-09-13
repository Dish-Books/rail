defmodule RailWeb.Components.DemoPlayerState do
  @moduledoc """
  Pure state machine for demo playback timing, navigation, and frame resolution.
  Implements the timing model specified in Spec 05 §9.5.
  """

  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment

  defstruct [
    :demo,
    segments: [],
    segment_index: 0,
    frame_index: 0,
    elapsed_ms: 0,
    is_playing: false,
    loop: false,
    auto_advance_segments: true
  ]

  @type t :: %__MODULE__{
          demo: term(),
          segments: list(),
          segment_index: non_neg_integer(),
          frame_index: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          is_playing: boolean(),
          loop: boolean(),
          auto_advance_segments: boolean()
        }

  @doc "Creates a new DemoPlayerState from a demo artifact or map."
  def new(demo, opts \\ []) do
    segments = resolve_segments(demo)
    total_segments = length(segments)

    initial_segment =
      opts
      |> Keyword.get(:segment_index, 0)
      |> clamp_index(total_segments)

    loop = Keyword.get(opts, :loop, false)
    auto_advance = Keyword.get(opts, :auto_advance_segments, true)
    is_playing = Keyword.get(opts, :is_playing, false)

    %__MODULE__{
      demo: demo,
      segments: segments,
      segment_index: initial_segment,
      frame_index: 0,
      elapsed_ms: 0,
      is_playing: is_playing,
      loop: loop,
      auto_advance_segments: auto_advance
    }
  end

  @doc "Returns the currently active segment or nil."
  def current_segment(%__MODULE__{segments: []}), do: nil

  def current_segment(%__MODULE__{segments: segments, segment_index: idx}) do
    Enum.at(segments, idx)
  end

  @doc "Returns the currently displayed frame, falling back to a synthetic frame."
  def current_frame(%__MODULE__{} = state) do
    case current_segment(state) do
      %{} = segment ->
        frames = get_frames(segment)

        if frames == [] do
          synthetic_frame()
        else
          idx = clamp_index(state.frame_index, length(frames))
          Enum.at(frames, idx) || synthetic_frame()
        end

      _other ->
        synthetic_frame()
    end
  end

  @doc "Returns the total duration of the current segment in milliseconds."
  def total_segment_ms(%__MODULE__{} = state) do
    case current_segment(state) do
      %{} = segment -> segment_duration_ms(segment)
      _other -> 0
    end
  end

  @doc "Returns true if there is a preceding segment."
  def has_prev_segment?(%__MODULE__{segment_index: idx}), do: idx > 0

  @doc "Returns true if there is a succeeding segment."
  def has_next_segment?(%__MODULE__{segments: segments, segment_index: idx}) do
    idx < length(segments) - 1
  end

  @doc "Returns true if there is a preceding frame in this or previous segment."
  def has_prev_frame?(%__MODULE__{frame_index: idx} = state) do
    idx > 0 or (state.auto_advance_segments and has_prev_segment?(state)) or
      (state.loop and state.segments != [])
  end

  @doc "Returns true if there is a succeeding frame in this or next segment."
  def has_next_frame?(%__MODULE__{frame_index: idx} = state) do
    frames_count =
      case current_segment(state) do
        %{} = seg -> length(get_frames(seg))
        _other -> 0
      end

    idx + 1 < frames_count or (state.auto_advance_segments and has_next_segment?(state)) or
      (state.loop and state.segments != [])
  end

  @doc "Starts playback, resetting to 0 if at the end of duration."
  def play(%__MODULE__{segments: []} = state), do: state

  def play(%__MODULE__{is_playing: true} = state), do: state

  def play(%__MODULE__{} = state) do
    total_ms = total_segment_ms(state)

    state =
      if state.elapsed_ms >= total_ms and total_ms > 0 do
        if has_next_segment?(state) and state.auto_advance_segments do
          next_segment(state)
        else
          seek(state, 0)
        end
      else
        state
      end

    %{state | is_playing: true}
  end

  @doc "Pauses playback."
  def pause(%__MODULE__{} = state) do
    %{state | is_playing: false}
  end

  @doc "Toggles between playing and paused."
  def toggle_play_pause(%__MODULE__{is_playing: true} = state), do: pause(state)
  def toggle_play_pause(%__MODULE__{is_playing: false} = state), do: play(state)

  @doc "Seeks to an explicit millisecond position within the current segment."
  def seek(%__MODULE__{} = state, target_ms) do
    total_ms = total_segment_ms(state)
    clamped_ms = max(0, min(target_ms, total_ms))

    frame_idx =
      case current_segment(state) do
        %{} = segment -> frame_index_from_elapsed(segment, clamped_ms)
        nil -> 0
      end

    %{state | elapsed_ms: clamped_ms, frame_index: frame_idx}
  end

  @doc "Advances to the next frame or segment."
  def next_frame(%__MODULE__{} = state) do
    case current_segment(state) do
      %{} = segment ->
        frames = get_frames(segment)
        total_frames = length(frames)

        cond do
          state.frame_index + 1 < total_frames ->
            new_idx = state.frame_index + 1
            new_elapsed = elapsed_for_frame_index(segment, new_idx)
            %{state | frame_index: new_idx, elapsed_ms: new_elapsed}

          has_next_segment?(state) and state.auto_advance_segments ->
            next_segment(state)

          state.loop and state.auto_advance_segments and state.segments != [] ->
            select_segment(state, 0)

          true ->
            state
        end

      nil ->
        state
    end
  end

  @doc "Steps back to the previous frame or previous segment."
  def prev_frame(%__MODULE__{} = state) do
    cond do
      state.frame_index > 0 ->
        case current_segment(state) do
          %{} = segment ->
            new_idx = state.frame_index - 1
            new_elapsed = elapsed_for_frame_index(segment, new_idx)
            %{state | frame_index: new_idx, elapsed_ms: new_elapsed}

          nil ->
            state
        end

      has_prev_segment?(state) ->
        prev_idx = state.segment_index - 1
        prev_seg = Enum.at(state.segments, prev_idx)
        frames_count = length(get_frames(prev_seg))
        last_frame_idx = max(0, frames_count - 1)
        new_elapsed = elapsed_for_frame_index(prev_seg, last_frame_idx)
        %{state | segment_index: prev_idx, frame_index: last_frame_idx, elapsed_ms: new_elapsed}

      state.loop and state.segments != [] ->
        last_seg_idx = length(state.segments) - 1
        last_seg = Enum.at(state.segments, last_seg_idx)
        frames_count = length(get_frames(last_seg))
        last_frame_idx = max(0, frames_count - 1)
        new_elapsed = elapsed_for_frame_index(last_seg, last_frame_idx)
        %{state | segment_index: last_seg_idx, frame_index: last_frame_idx, elapsed_ms: new_elapsed}

      true ->
        state
    end
  end

  @doc "Selects the next segment."
  def next_segment(%__MODULE__{} = state) do
    cond do
      has_next_segment?(state) ->
        select_segment(state, state.segment_index + 1)

      state.loop and state.segments != [] ->
        select_segment(state, 0)

      true ->
        state
    end
  end

  @doc "Selects the previous segment."
  def prev_segment(%__MODULE__{} = state) do
    cond do
      has_prev_segment?(state) ->
        select_segment(state, state.segment_index - 1)

      state.loop and state.segments != [] ->
        select_segment(state, length(state.segments) - 1)

      true ->
        state
    end
  end

  @doc "Selects a specific segment index, resetting elapsed time and frame index."
  def select_segment(%__MODULE__{segments: segments} = state, idx) do
    clamped = clamp_index(idx, length(segments))
    %{state | segment_index: clamped, frame_index: 0, elapsed_ms: 0}
  end

  @doc "Toggles looping mode."
  def toggle_loop(%__MODULE__{} = state) do
    %{state | loop: not state.loop}
  end

  @doc "Ticks elapsed time by delta_ms, updating frame index and advancing segments when appropriate."
  def tick(%__MODULE__{is_playing: false} = state, _delta_ms), do: state
  def tick(%__MODULE__{segments: []} = state, _delta_ms), do: state

  def tick(%__MODULE__{} = state, delta_ms) when is_integer(delta_ms) and delta_ms > 0 do
    new_elapsed = state.elapsed_ms + delta_ms
    total_ms = total_segment_ms(state)

    cond do
      new_elapsed < total_ms ->
        segment = current_segment(state)
        frame_idx = frame_index_from_elapsed(segment, new_elapsed)
        %{state | elapsed_ms: new_elapsed, frame_index: frame_idx}

      has_next_segment?(state) and state.auto_advance_segments ->
        next_segment(state)

      state.loop and state.auto_advance_segments and length(state.segments) > 1 ->
        select_segment(state, 0)

      state.loop and length(state.segments) == 1 ->
        %{state | elapsed_ms: 0, frame_index: 0}

      true ->
        segment = current_segment(state)
        last_frame_idx = max(0, length(get_frames(segment)) - 1)
        %{state | elapsed_ms: total_ms, frame_index: last_frame_idx, is_playing: false}
    end
  end

  @doc "Returns the proxied asset URL or local path for a demo frame."
  def frame_url(frame) do
    cond do
      is_binary(frame_field(frame, :linear_asset_id)) and
          frame_field(frame, :linear_asset_id) != "" ->
        Rail.Artifacts.asset_url(:demo, frame_field(frame, :linear_asset_id))

      is_binary(frame_field(frame, :url)) and frame_field(frame, :url) != "" ->
        frame_field(frame, :url)

      is_binary(frame_field(frame, :path)) and frame_field(frame, :path) != "" ->
        frame_field(frame, :path)

      true ->
        ""
    end
  end

  @doc "Helper to extract frame hold_ms."
  def frame_hold_ms(frame) do
    val = frame_field(frame, :hold_ms)
    if is_integer(val) and val > 0, do: val, else: 1000
  end

  @doc "Helper to extract frame caption."
  def frame_caption(frame) do
    case frame_field(frame, :caption) do
      caption when is_binary(caption) -> caption
      _other -> nil
    end
  end

  # --- Private Helpers ---

  defp resolve_segments(nil), do: []

  defp resolve_segments(%{segments: segments}) when is_list(segments), do: segments

  defp resolve_segments(%{"segments" => segments}) when is_list(segments), do: segments

  defp resolve_segments(_other), do: []

  defp clamp_index(_idx, 0), do: 0

  defp clamp_index(idx, total) when is_integer(idx) do
    max(0, min(idx, total - 1))
  end

  defp clamp_index(_other, _total), do: 0

  defp get_frames(%DemoSegment{frames: frames}) when is_list(frames), do: frames

  defp get_frames(%{frames: frames}) when is_list(frames), do: frames

  defp get_frames(%{"frames" => frames}) when is_list(frames), do: frames

  defp get_frames(_other), do: []

  defp segment_duration_ms(%DemoSegment{} = seg), do: DemoSegment.duration_ms(seg)

  defp segment_duration_ms(%{duration_ms: ms}) when is_integer(ms), do: ms

  defp segment_duration_ms(%{"duration_ms" => ms}) when is_integer(ms), do: ms

  defp segment_duration_ms(seg) do
    frames = get_frames(seg)

    if frames == [] do
      1000
    else
      Enum.reduce(frames, 0, fn frame, acc ->
        acc + frame_hold_ms(frame)
      end)
    end
  end

  defp elapsed_for_frame_index(_segment, target_idx) when target_idx <= 0, do: 0

  defp elapsed_for_frame_index(segment, target_idx) do
    frames = get_frames(segment)

    frames
    |> Enum.take(target_idx)
    |> Enum.reduce(0, fn frame, acc -> acc + frame_hold_ms(frame) end)
  end

  defp frame_index_from_elapsed(segment, elapsed_ms) do
    frames = get_frames(segment)
    total_frames = length(frames)

    if total_frames <= 1 do
      0
    else
      {_running, found_idx} =
        Enum.reduce_while(Enum.with_index(frames), {0, 0}, fn {frame, idx}, {running, _last_idx} ->
          hold = frame_hold_ms(frame)
          next_running = running + hold

          if elapsed_ms < next_running do
            {:halt, {next_running, idx}}
          else
            {:cont, {next_running, idx}}
          end
        end)

      found_idx
    end
  end

  defp frame_field(%DemoFrame{} = frame, key), do: Map.get(frame, key)

  defp frame_field(frame, key) when is_map(frame) do
    Map.get(frame, key) || Map.get(frame, to_string(key))
  end

  defp frame_field(_other, _key), do: nil

  defp synthetic_frame do
    %DemoFrame{url: "", hold_ms: 1000, caption: nil}
  end
end

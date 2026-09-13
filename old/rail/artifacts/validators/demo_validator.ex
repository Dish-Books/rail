defmodule Rail.Artifacts.Validators.DemoValidator do
  @moduledoc """
  Validates agent-produced demo manifests and frame assets in scratch storage.
  """

  import Rail.Artifacts.Utils.PathConfinement

  @valid_outcomes ["recorded", "declined", "failed"]
  @min_hold_ms 200
  @max_hold_ms 15_000
  @max_frames_per_segment 40
  @max_total_bytes 50 * 1024 * 1024

  @doc """
  Validates a demo directory containing `manifest.json` and frame stills.
  """
  def validate(demo_dir, opts \\ []) when is_binary(demo_dir) do
    manifest_path = Path.join(demo_dir, "manifest.json")

    with {:ok, content} <- read_file(manifest_path),
         {:ok, data} <- parse_json(content),
         {:ok, raw_outcome} <- fetch_outcome(data),
         {:ok, outcome} <- validate_outcome(raw_outcome) do
      version = Map.get(data, "version", 1) || 1
      note = sanitize_note(data["note"])

      if outcome in ["declined", "failed"] do
        validate_declined_or_failed(outcome, version, note, data)
      else
        criteria = Keyword.get(opts, :criteria)
        validate_recorded(demo_dir, version, note, data, criteria)
      end
    end
  end

  @doc """
  Normalizes criteria text: strips markdown emphasis `[*_`#]`,
  collapses whitespace, trims, and downcases.
  """
  def normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[*_`#]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.downcase()
  end

  def normalize_text(nil), do: ""

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "Demo manifest not found at #{path}."}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _not_map} -> {:error, "Demo manifest must be a JSON object."}
      {:error, reason} -> {:error, "Failed to parse demo manifest: #{inspect(reason)}"}
    end
  end

  defp fetch_outcome(data) do
    case Map.get(data, "outcome") do
      outcome when is_binary(outcome) and outcome != "" -> {:ok, outcome}
      _missing -> {:error, "Manifest missing \"outcome\" field."}
    end
  end

  defp validate_outcome(raw_outcome) do
    if raw_outcome in @valid_outcomes do
      {:ok, raw_outcome}
    else
      {:error, "Invalid demo outcome: \"#{raw_outcome}\"."}
    end
  end

  defp sanitize_note(note) when is_binary(note), do: String.trim(note)
  defp sanitize_note(_other), do: nil

  defp validate_declined_or_failed(outcome, version, note, data) do
    segments = Map.get(data, "segments")

    cond do
      is_nil(note) or note == "" ->
        {:error, "A #{outcome} demo requires a non-empty note explaining why."}

      is_list(segments) and segments != [] ->
        {:error, "A #{outcome} demo must not contain segments."}

      true ->
        {:ok,
         %{
           outcome: outcome,
           version: version,
           note: note,
           recorded_at: DateTime.utc_now(),
           segments: []
         }}
    end
  end

  defp validate_recorded(demo_dir, version, note, data, criteria) do
    segments = Map.get(data, "segments")

    cond do
      not is_list(segments) or segments == [] ->
        {:error, "A recorded demo requires a non-empty list of segments."}

      is_list(criteria) and length(segments) != length(criteria) ->
        {:error,
         "Manifest contains #{length(segments)} segments, but the ticket defines #{length(criteria)} acceptance criteria."}

      true ->
        validate_segments(demo_dir, segments, criteria, version, note)
    end
  end

  defp validate_segments(demo_dir, segments, criteria, version, note) do
    initial_acc = {:ok, [], 0, false}

    result =
      segments
      |> Enum.with_index()
      |> Enum.reduce_while(initial_acc, fn {seg, idx}, {:ok, acc_segs, acc_bytes, has_recorded} ->
        expected_criterion = if is_list(criteria), do: Enum.at(criteria, idx)

        case validate_segment(demo_dir, seg, idx, expected_criterion, acc_bytes) do
          {:ok, validated_seg, seg_bytes, seg_recorded?} ->
            new_acc_bytes = acc_bytes + seg_bytes

            if new_acc_bytes > @max_total_bytes do
              {:halt, {:error, "Total demo frame size exceeds 50 MB limit."}}
            else
              {:cont, {:ok, [validated_seg | acc_segs], new_acc_bytes, has_recorded or seg_recorded?}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, _rev_segs, _bytes, false} ->
        {:error, "A recorded demo must have at least one recorded segment."}

      {:ok, rev_segs, _bytes, true} ->
        {:ok,
         %{
           outcome: "recorded",
           version: version,
           note: note,
           recorded_at: DateTime.utc_now(),
           segments: Enum.reverse(rev_segs)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_segment(demo_dir, seg, idx, expected_criterion, _acc_bytes) when is_map(seg) do
    with :ok <- validate_criterion_index(seg, idx),
         :ok <- validate_criterion_match(seg, idx, expected_criterion),
         {:ok, outcome_atom, _raw_outcome} <- resolve_segment_outcome(seg, idx) do
      seg_note = sanitize_note(seg["note"])
      frames = Map.get(seg, "frames", [])

      if outcome_atom in [:not_filmable, :failed] do
        validate_unfilmable_segment(idx, outcome_atom, seg_note, frames, seg)
      else
        validate_recorded_segment(demo_dir, idx, seg_note, frames, seg)
      end
    end
  end

  defp validate_segment(_demo_dir, _seg, idx, _expected_criterion, _acc_bytes) do
    {:error, "Segment at index #{idx} must be an object."}
  end

  defp validate_criterion_index(seg, idx) do
    expected_index = idx + 1
    actual_index = Map.get(seg, "criterionIndex") || expected_index

    if actual_index == expected_index do
      :ok
    else
      {:error, "Segment at index #{idx} has criterionIndex #{actual_index}, expected #{expected_index}."}
    end
  end

  defp validate_criterion_match(_seg, _idx, nil), do: :ok

  defp validate_criterion_match(seg, idx, expected_criterion) do
    actual_norm = normalize_text(seg["criterion"] || "")
    expected_norm = normalize_text(expected_criterion)

    if actual_norm == expected_norm do
      :ok
    else
      {:error, "Segment #{idx + 1} criterion text does not match acceptance criterion #{idx + 1}."}
    end
  end

  defp resolve_segment_outcome(seg, idx) do
    raw = Map.get(seg, "outcome", "recorded")

    case raw do
      "recorded" -> {:ok, :recorded, raw}
      "not_filmable" -> {:ok, :not_filmable, raw}
      "notFilmable" -> {:ok, :not_filmable, raw}
      "failed" -> {:ok, :failed, raw}
      _other -> {:error, "Segment #{idx + 1} has invalid outcome: \"#{raw}\"."}
    end
  end

  defp validate_unfilmable_segment(idx, outcome_atom, seg_note, frames, seg) do
    cond do
      is_nil(seg_note) or seg_note == "" ->
        {:error, "Segment #{idx + 1} (#{outcome_atom}) requires a note explaining why."}

      is_list(frames) and frames != [] ->
        {:error, "Segment #{idx + 1} (#{outcome_atom}) must not contain frames."}

      true ->
        validated = %{
          criterion_index: idx + 1,
          criterion: seg["criterion"] || "",
          outcome: outcome_atom,
          note: seg_note,
          frames: []
        }

        {:ok, validated, 0, false}
    end
  end

  defp validate_recorded_segment(demo_dir, idx, seg_note, frames, seg) do
    cond do
      not is_list(frames) or frames == [] ->
        {:error, "Segment #{idx + 1} is marked recorded but has no frames."}

      length(frames) > @max_frames_per_segment ->
        {:error, "Segment #{idx + 1} exceeds the maximum limit of 40 frames (has #{length(frames)})."}

      true ->
        validate_frames(demo_dir, idx, seg_note, frames, seg)
    end
  end

  defp validate_frames(demo_dir, idx, seg_note, frames, seg) do
    initial = {:ok, [], 0}

    frame_result =
      frames
      |> Enum.with_index()
      |> Enum.reduce_while(initial, fn {frame, f_idx}, {:ok, acc_frames, acc_bytes} ->
        case validate_single_frame(demo_dir, idx, f_idx, frame) do
          {:ok, validated_frame, frame_bytes} ->
            {:cont, {:ok, [validated_frame | acc_frames], acc_bytes + frame_bytes}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case frame_result do
      {:ok, rev_frames, total_bytes} ->
        validated = %{
          criterion_index: idx + 1,
          criterion: seg["criterion"] || "",
          outcome: :recorded,
          note: seg_note,
          frames: Enum.reverse(rev_frames)
        }

        {:ok, validated, total_bytes, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_single_frame(demo_dir, seg_idx, frame_idx, frame) when is_map(frame) do
    raw_path = frame["path"]
    hold_ms = Map.get(frame, "holdMs", 1000) || 1000
    caption = sanitize_note(frame["caption"])

    with :ok <- validate_frame_path_non_empty(seg_idx, frame_idx, raw_path),
         :ok <- validate_hold_ms(seg_idx, frame_idx, hold_ms),
         {:ok, canonical_path} <- verify_frame_confinement(demo_dir, seg_idx, frame_idx, raw_path),
         {:ok, file_size} <- check_frame_file(seg_idx, frame_idx, canonical_path, raw_path) do
      validated_frame = %{
        path: raw_path,
        resolved_path: canonical_path,
        hold_ms: hold_ms,
        caption: caption,
        size: file_size
      }

      {:ok, validated_frame, file_size}
    end
  end

  defp validate_single_frame(_demo_dir, seg_idx, frame_idx, _frame) do
    {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} must be an object."}
  end

  defp validate_frame_path_non_empty(seg_idx, frame_idx, raw_path) do
    if is_binary(raw_path) and raw_path != "" do
      :ok
    else
      {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} is missing a path."}
    end
  end

  defp validate_hold_ms(seg_idx, frame_idx, hold_ms) do
    if is_integer(hold_ms) and hold_ms >= @min_hold_ms and hold_ms <= @max_hold_ms do
      :ok
    else
      {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} holdMs (#{hold_ms}) must be between 200 and 15000 ms."}
    end
  end

  defp verify_frame_confinement(demo_dir, seg_idx, frame_idx, raw_path) do
    case verify_confinement(demo_dir, raw_path, allow_root: true) do
      {:ok, path} ->
        {:ok, path}

      {:error, :escapes_confinement} ->
        {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} path \"#{raw_path}\" is outside demo directory."}
    end
  end

  defp check_frame_file(seg_idx, frame_idx, canonical_path, raw_path) do
    case File.stat(canonical_path) do
      {:ok, %{type: :regular, size: size}} when size > 0 ->
        {:ok, size}

      {:ok, %{type: :regular, size: 0}} ->
        {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} file is empty: \"#{raw_path}\"."}

      _other ->
        {:error, "Segment #{seg_idx + 1} frame #{frame_idx + 1} file does not exist: \"#{raw_path}\"."}
    end
  end
end

defmodule Rail.Tools.Actions.EncodeRecording do
  @moduledoc """
  Turns a directory of recorded frames into one video file.

  The frames are already JPEGs, and keeping them would cost tens of megabytes for
  a walkthrough of a couple of minutes. VP9 in a WebM container brings the same
  two minutes down to a few, which is the difference between an artifact a person
  opens and one they wait for. The video is 1920x1080, and a frame of another size
  is fitted inside it and padded, never stretched, so the player never resizes.

  Nothing is drawn on top of it either. The captions are a file beside the video
  and the player renders them under it, so every pixel of the recording is a
  pixel of the application.

  ffmpeg's concat demuxer is what makes the timing exact: every frame is given
  its own duration rather than everything being averaged into one frame rate. A
  page that animated plays at the speed it animated at. A page nothing happened
  on for forty seconds does not - `Rail.Tools.Utils.CompressTimeline` caps how
  long a still frame holds, and drops what was filmed after the last caption was
  read - so the video is what was shown rather than how long it took to show it.
  A voiced take is cut by its lines and the page's actions instead, in
  `Rail.Tools.Utils.FollowVoiceOver`, since a spinner never lets a frame hold.
  What the page did from a recorder's cut to the next caption is setup, so no
  beat gets it, and a cut also ends the beat before it.

  A machine with no ffmpeg is a machine that records but cannot encode. That is
  reported rather than raised: the frames are still there, and whoever reads the
  error can install it and encode the same recording again.
  """

  import Rail.Tools.Utils.CompressTimeline
  import Rail.Tools.Utils.FollowVoiceOver

  alias Rail.Tools

  @doc """
  Encodes the frames in `directory` into `directory/demo.webm`.

  `marks` are the captions, each `{at_ms, for_ms}` on the recording's clock - when
  it was said and, by `timing`, the time it takes to read (`:reading`) or to say
  (`:spoken`). Only the frames the timeline keeps are encoded. Returns `{:ok, path,
  video_times}`, where `video_times` is where each mark begins in the video, in
  the order given.

  Returns `{:error, :nothing_recorded}` when no frame was ever written,
  `{:error, :no_ffmpeg}` on a machine that has none, and `{:error,
  {:encode_failed, output}}` when ffmpeg ran and refused. The three are different
  things to tell somebody: one is a recording that never happened, one is a
  machine to fix, and one is a recording to look at.
  """
  def encode_recording(directory, marks, timing) when timing in [:reading, :spoken] do
    case frames(directory) do
      [] ->
        {:error, :nothing_recorded}

      frames when timing == :reading ->
        encode(directory, compress_timeline(frames, marks))

      frames ->
        cuts = directory |> written("cuts.jsonl") |> Enum.map(fn %{"at_ms" => cut} -> cut end)
        encode(directory, follow_voice_over(frames, marks, actions(directory, marks, cuts), cuts))
    end
  end

  defp encode(directory, {frames, video_times}) do
    manifest = Path.join(directory, "frames.txt")
    video = Path.join(directory, "demo.webm")

    File.write!(manifest, concat(frames))

    case ffmpeg(manifest, video) do
      {:ok, {_output, 0}} -> {:ok, video, video_times}
      {:ok, {output, _failed}} -> {:error, {:encode_failed, String.trim(output)}}
      {:error, :no_ffmpeg} -> {:error, :no_ffmpeg}
    end
  end

  # An executable nothing on the path matches is handed to the port bare and the
  # port raises, which is the one failure here that is about the machine rather
  # than about the recording.
  defp ffmpeg(manifest, video) do
    {:ok,
     Tools.run("ffmpeg", ["-y", "-f", "concat", "-safe", "0", "-i", manifest] ++ encode(video), stderr_to_stdout: true)}
  rescue
    ErlangError -> {:error, :no_ffmpeg}
  end

  # A tab painted at two sizes hands ffmpeg frames of both, and a WebM that changes size mid-stream resizes the
  # player. `-crf 36` with no bitrate is VP9's constant-quality mode, which keeps a mostly-still recording small.
  defp encode(video) do
    ["-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2"] ++
      ["-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", video]
  end

  # One `file`/`duration` pair per frame, plus the last file repeated: the concat
  # demuxer ignores the final entry's duration and shows the last frame for an
  # instant unless it is listed twice. Paths are relative to the manifest, which
  # is why `-safe 0` is not needed for safety so much as for the nested directory.
  defp concat(frames) do
    last = List.last(frames)

    [Enum.map(frames, &entry/1), "file 'frames/", last.file, "'\n"]
  end

  defp entry(frame), do: ["file 'frames/", frame.file, "'\nduration ", seconds(frame.hold_ms), "\n"]

  # A frame that arrived in the same millisecond as the one before it still has
  # to hold for something, or ffmpeg drops it and the timings behind it shift.
  defp seconds(ms) when ms < 1, do: "0.001"
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)

  # In the order they were written, which is the order the file is appended in.
  defp frames(directory) do
    directory
    |> written("frames.jsonl")
    |> Enum.map(fn %{"file" => file, "at_ms" => at_ms} -> %{file: file, at_ms: at_ms} end)
  end

  # A take recorded before the page reported its actions has none, and each line plays at its caption. A cut
  # with no caption after it runs to the end of the take.
  defp actions(directory, marks, cuts) do
    said = marks |> Enum.map(fn {at_ms, _for_ms} -> at_ms end) |> Enum.sort()
    windows = Enum.map(cuts, fn cut -> {cut, Enum.find(said, &(&1 >= cut))} end)

    directory
    |> written("actions.jsonl")
    |> Enum.map(fn %{"at_ms" => at_ms} -> at_ms end)
    |> Enum.reject(fn at_ms ->
      Enum.any?(windows, fn {cut, next} -> at_ms >= cut and (is_nil(next) or at_ms < next) end)
    end)
  end

  # A half-written last line was landing as the recording stopped; it is skipped rather than guessed at.
  defp written(directory, file) do
    directory
    |> Path.join(file)
    |> File.read()
    |> case do
      {:ok, written} -> written
      {:error, _none} -> ""
    end
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> [decoded]
        {:error, _half_written} -> []
      end
    end)
  end
end

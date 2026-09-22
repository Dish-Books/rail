defmodule Rail.Tools.Actions.EncodeRecording do
  @moduledoc """
  Turns a directory of recorded frames into one video file.

  The frames are already JPEGs, and keeping them would cost tens of megabytes for
  a walkthrough of a couple of minutes. VP9 in a WebM container brings the same
  two minutes down to a few, which is the difference between an artifact a person
  opens and one they wait for. Nothing is scaled: the browser records at
  1920x1080 and the video is 1920x1080, because a demo is watched to see the
  application and a downscale is exactly what makes small text unreadable.

  Nothing is drawn on top of it either. The captions are a file beside the video
  and the player renders them under it, so every pixel of the recording is a
  pixel of the application.

  ffmpeg's concat demuxer is what makes the timing exact: every frame is given
  its own duration rather than everything being averaged into one frame rate. A
  page that animated plays at the speed it animated at. A page nothing happened
  on for forty seconds does not - `Rail.Tools.Utils.CompressTimeline` caps how
  long a still frame holds, except while a caption is up and needs reading - so
  the video is what was shown rather than how long it took to show it.

  A machine with no ffmpeg is a machine that records but cannot encode. That is
  reported rather than raised: the frames are still there, and whoever reads the
  error can install it and encode the same recording again.
  """

  import Rail.Tools.Utils.CompressTimeline

  alias Rail.Tools

  @doc """
  Encodes the frames in `directory` into `directory/demo.webm`.

  `marks` are the stretches of the recording that must play at real speed, each
  `{at_ms, for_ms}` on the recording's clock - a caption and the time it takes
  to read. Returns `{:ok, path, video_times}`, where `video_times` is where each
  mark begins in the video, in the order given.

  Returns `{:error, :nothing_recorded}` when no frame was ever written,
  `{:error, :no_ffmpeg}` on a machine that has none, and `{:error,
  {:encode_failed, output}}` when ffmpeg ran and refused. The three are different
  things to tell somebody: one is a recording that never happened, one is a
  machine to fix, and one is a recording to look at.
  """
  def encode_recording(directory, marks \\ []) do
    case frames(directory) do
      [] -> {:error, :nothing_recorded}
      frames -> encode(directory, compress_timeline(frames, marks))
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

  # Every frame ffmpeg is handed is 1920x1080 already, so the encoder's only job
  # is the codec. `-crf 36` with no bitrate is VP9's constant-quality mode, which
  # is what keeps a mostly-still screen recording small.
  defp encode(video) do
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
  # A half-written last line is a frame that was landing as the recording stopped;
  # it is skipped rather than guessed at.
  defp frames(directory) do
    directory
    |> Path.join("frames.jsonl")
    |> File.read()
    |> case do
      {:ok, written} -> written
      {:error, _none} -> ""
    end
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"file" => file, "at_ms" => at_ms}} -> [%{file: file, at_ms: at_ms}]
        _unreadable -> []
      end
    end)
  end
end

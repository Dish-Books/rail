defmodule Rail.Tools.Actions.MixVoiceOver do
  @moduledoc """
  Lays the clips `record_voice_over/2` spoke onto one track, each starting where its caption plays in the encoded
  video, and muxes it into the demo, so the voice-over is in the file wherever it is watched. A clip that would
  start before the one ahead of it has finished waits for it, so no two lines are spoken at once.
  """

  alias Rail.Tools
  alias Rail.Tools.Clients.Speech

  @doc """
  Mixes `directory/narration/<n>.pcm` into `directory/demo.webm`, clip n starting at `starts_ms`'s nth entry.
  Returns `{:ok, video}`, `{:error, :no_ffmpeg}`, or `{:error, {:encode_failed, output}}` with the silent video
  left as it was.
  """
  def mix_voice_over(directory, starts_ms) when is_list(starts_ms) do
    track = Path.join(directory, "narration.pcm")
    video = Path.join(directory, "demo.webm")
    voiced = Path.join(directory, "demo.voiced.webm")
    File.write!(track, track(directory, starts_ms))

    case ffmpeg(video, track, voiced) do
      {:ok, {_output, 0}} ->
        File.rename!(voiced, video)
        {:ok, video}

      {:ok, {output, _failed}} ->
        File.rm(voiced)
        {:error, {:encode_failed, String.trim(output)}}

      {:error, :no_ffmpeg} ->
        {:error, :no_ffmpeg}
    end
  end

  # Silence up to each clip's start, then the clip; 2 bytes a sample.
  defp track(directory, starts_ms) do
    per_ms = div(Speech.rate() * 2, 1000)

    {track, _end} =
      starts_ms
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {start_ms, index}, {track, at} ->
        clip = File.read!(Path.join([directory, "narration", "#{index}.pcm"]))
        start = max(start_ms * per_ms, at)
        {[track, :binary.copy(<<0>>, start - at), clip], start + byte_size(clip)}
      end)

    track
  end

  defp ffmpeg(video, track, voiced) do
    {:ok,
     Tools.run(
       "ffmpeg",
       ["-y", "-i", video, "-f", "s16le", "-ar", to_string(Speech.rate()), "-ac", "1", "-i", track] ++
         ["-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", voiced],
       stderr_to_stdout: true
     )}
  rescue
    ErlangError -> {:error, :no_ffmpeg}
  end
end

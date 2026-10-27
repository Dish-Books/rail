defmodule Rail.Tools.Actions.RecordVoiceOver do
  @moduledoc """
  Speaks each of a demo's captions into a clip of its own, before the video is encoded, so the encode can time each
  beat by how long its line takes to say.
  """

  alias Rail.Tools.Clients.Speech

  @doc """
  Speaks `lines` in order into `directory/narration/<n>.pcm`. Returns `{:ok, durations_ms}`, one for each line, or
  the first line's error, with no clips left behind.
  """
  def record_voice_over(directory, lines) when is_list(lines) do
    folder = Path.join(directory, "narration")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)

    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, durations} ->
      case Speech.synthesize(line) do
        {:ok, pcm} ->
          File.write!(Path.join(folder, "#{index}.pcm"), pcm)
          {:cont, {:ok, [div(byte_size(pcm) * 1000, Speech.rate() * 2) | durations]}}

        {:error, reason} ->
          File.rm_rf!(folder)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, durations} -> {:ok, Enum.reverse(durations)}
      {:error, reason} -> {:error, reason}
    end
  end
end

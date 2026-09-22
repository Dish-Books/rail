defmodule Rail.Pipeline.Actions.ListDemoBeats do
  @moduledoc """
  Every caption a demo run has stamped so far, in the order they play.

  Read from the file rather than from rows, for the same reason the QA
  screenshots are: the point of watching a recording being made is seeing the
  beats land while it is still going, and a run that dies half way has still
  narrated everything it got to.

  One JSON object a line, appended while the run works, so the last line can be
  half written. Anything unreadable is skipped rather than raised over. Once the
  video is encoded each line also carries `video_ms`, which is where that caption
  plays in it.
  """

  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Lists `task`'s demo beats as `%DemoBeat{}`, earliest first.

  `at_ms` is where each plays in the video once one has been encoded, and where
  it was said until then. `recorded_ms` is always where it was said.
  """
  def list_demo_beats(%Task{scratch_path: scratch_path}) do
    [scratch_path, "demo", "captions.jsonl"]
    |> Path.join()
    |> File.read()
    |> case do
      {:ok, written} -> written
      {:error, _none} -> ""
    end
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&beat/1)
    |> Enum.sort_by(& &1.at_ms)
  end

  defp beat(line) do
    case Jason.decode(line) do
      {:ok, %{"at_ms" => at_ms, "text" => text} = beat} when is_integer(at_ms) and is_binary(text) ->
        [
          %DemoBeat{
            at_ms: video_ms(beat["video_ms"], at_ms),
            recorded_ms: at_ms,
            text: String.trim(text),
            criterion: criterion(beat["criterion"])
          }
        ]

      _unreadable ->
        []
    end
  end

  defp video_ms(video_ms, _recorded_ms) when is_integer(video_ms), do: video_ms
  defp video_ms(_not_encoded, recorded_ms), do: recorded_ms

  defp criterion(criterion) when is_binary(criterion) do
    case String.trim(criterion) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp criterion(_none), do: nil
end

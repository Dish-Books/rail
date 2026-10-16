defmodule Rail.Mcp.Utils.RunToolDemoSay do
  @moduledoc """
  Records one caption against the recording's own clock.

  The agent supplies the words and Rail supplies the time, which is the only
  division that works: the agent has no idea how long the browser took to paint
  the last page, and the recording has no idea what is about to happen. So a
  caption is said immediately before the thing it narrates and lands on the frame
  where that thing begins.

  A caption before `demo_start` belongs to no video, so it is refused rather than
  stamped against a recording that is not running. Saying so is what tells an
  agent that has forgotten the order.

  Appended a line at a time rather than written whole, exactly as the QA
  screenshots' captions are: a run that dies half way keeps every beat it had
  already narrated, and the panel reads what is there.

  The caption is never drawn on the video. It is read back beside it and rendered
  under it, so the recording stays a recording of the application and nothing
  else.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder

  @doc """
  Stamps `arguments["text"]` at the recording's current position and says where
  it landed.
  """
  def run_tool_demo_say(%Task{} = task, %{"text" => text} = arguments, _opts) when is_binary(text) do
    recorder = Tools.get_browser_recording(task)
    # The caption is spoken word for word, and a symbol such as the hyphen in "Cash - Main" has no one spoken form.
    symbols = ~r/[^\p{L}\p{M}\p{Nd}\s.,;:?!'’]/u |> Regex.scan(text) |> List.flatten() |> Enum.uniq()

    cond do
      is_nil(recorder) ->
        {:refused, "Nothing is recording, so that caption would belong to no video. Call demo_start first."}

      symbols != [] ->
        {:refused,
         "The caption is spoken aloud, so it is written in words, numbers and sentence punctuation only, and " <>
           "#{Enum.map_join(symbols, ", ", &inspect/1)} cannot be said. Write it in words and say it again. " <>
           "Nothing was recorded."}

      true ->
        said(task, recorder, text, arguments["criterion"])
    end
  end

  def run_tool_demo_say(%Task{}, _arguments, _opts), do: {:refused, "demo_say needs a `text`. Nothing was recorded."}

  defp said(%Task{} = task, recorder, text, criterion) do
    at_ms = BrowserRecorder.elapsed_ms(recorder)

    append(task, %{at_ms: at_ms, text: text, criterion: criterion})
    Pipeline.broadcast_output_saved(task)

    {:ok, "Said at #{DemoBeat.stamp(at_ms)}. Do the thing you just described now, while the caption is up."}
  end

  defp append(%Task{scratch_path: scratch_path}, beat) do
    path = Path.join([scratch_path, "demo", "captions.jsonl"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(beat), "\n"], [:append])
  end
end

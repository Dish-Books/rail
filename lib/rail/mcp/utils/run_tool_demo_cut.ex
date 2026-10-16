defmodule Rail.Mcp.Utils.RunToolDemoCut do
  @moduledoc """
  Marks where the recorder starts setting up for the next beat, on the recording's own clock.

  No timing rule tells setup from a beat's next step, so the recorder says when it starts, and a voiced encode
  leaves out what the page does from the cut to the next caption.
  """

  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder

  @doc """
  Stamps a cut at the recording's current position and says where it landed.
  """
  def run_tool_demo_cut(%Task{scratch_path: scratch_path} = task, _arguments, _opts) do
    case Tools.get_browser_recording(task) do
      recorder when is_pid(recorder) ->
        at_ms = BrowserRecorder.elapsed_ms(recorder)
        path = Path.join([scratch_path, "demo", "cuts.jsonl"])

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, [Jason.encode_to_iodata!(%{at_ms: at_ms}), "\n"], [:append])

        {:ok,
         "Cut at #{DemoBeat.stamp(at_ms)}. What the page does from here to your next caption is left out of the video."}

      nil ->
        {:refused, "Nothing is recording, so there is nothing to cut. Call demo_start first."}
    end
  end
end

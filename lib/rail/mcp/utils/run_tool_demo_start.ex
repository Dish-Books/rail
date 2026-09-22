defmodule Rail.Mcp.Utils.RunToolDemoStart do
  @moduledoc """
  Starts the take, and throws away everything filmed before it.

  Recording used to begin at a demo run's first tool call, which meant the film
  opened on a login screen and then showed the agent working out how the
  application behaves - a five minute video of ninety seconds of walkthrough. The
  driving that a demo learns from is not the demo.

  So the camera is the agent's to switch on. It signs in, drives the flow once to
  find out how it goes, puts the data back, and then calls this and does the run
  it now knows. Calling it again is another take: the frames and the captions from
  the last one go, because a demo is the take that worked rather than all of them.

  The clock restarts with the frames, so a caption stamped after this lands where
  it belongs in the video this is the start of.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Begins recording `task`, discarding any earlier take.
  """
  def run_tool_demo_start(%Task{} = task, _arguments, _opts) do
    _discarded = Tools.stop_browser_recording(task)
    {:ok, _recording} = Tools.start_browser_recording(task)

    {:ok, "Recording. Everything from here is in the video, so do the walkthrough you rehearsed."}
  end
end

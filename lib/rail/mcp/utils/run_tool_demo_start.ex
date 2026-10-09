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
  it belongs in the video this is the start of. Chrome only paints when the page
  changes, so the take opens on the frame already on screen rather than waiting
  for the next change to start the clock.
  """

  import Rail.Mcp.Utils.BrowserName
  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Begins recording the browser `arguments["browser"]` names on `task`, discarding
  any earlier take.
  """
  def run_tool_demo_start(%Task{} = task, arguments, opts) do
    with {:ok, name} <- filmed(task, arguments, opts) do
      _discarded = Tools.stop_browser_recording(task)
      {:ok, recording} = Tools.start_browser_recording(task, name)

      with "" <> frame <- Tools.get_browser_frame(task, name), do: send(recording, {:browser_frame, task.id, frame})

      {:ok, "Recording. Everything from here is in the video, so do the walkthrough you rehearsed."}
    end
  end

  # A take of a browser nobody connected would record nothing, and the agent would
  # only learn so once the run ended.
  defp filmed(task, %{"browser" => _given} = arguments, opts) do
    with {:ok, name, _session} <- named_browser(task, arguments, opts), do: {:ok, name}
  end

  defp filmed(_task, arguments, opts), do: browser_name(arguments, opts)
end

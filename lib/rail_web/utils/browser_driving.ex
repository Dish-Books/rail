defmodule RailWeb.Utils.BrowserDriving do
  @moduledoc """
  What a run is doing to the browser right now, for the panels that watch one.

  Two stages drive the same Chrome for different reasons, and a person standing
  behind either of them asks the same three things: what is it looking at, where
  is that, and what did it just do. So the answer is one shape read one way -
  the frame off the session, the rest off the run's own log.

  What is in that log is what Rail executed rather than what the agent asked
  for, so a step that went to the wrong element reads as the wrong element.
  """

  import Rail.Pipeline.Utils.DrivingLine

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  # A run that has not been given an instruction yet reads as waiting for one
  # rather than as a blank line where the instruction goes.
  @waiting "Waiting for the first instruction."

  @doc """
  Returns `%{doing:, verb:, target:, url:, frame:}` for `run` driving `task`.

  A run that is not executing is driving nothing, whatever is still painted in
  the browser: a Chrome left open by the run before this one would otherwise
  read as this one's first page.
  """
  def browser_driving(run, %Task{} = task) do
    if Run.running?(run), do: driving(run, task), else: idle()
  end

  defp idle, do: %{doing: nil, verb: "idle", target: @waiting, url: nil, frame: nil}

  defp driving(%Run{} = run, %Task{} = task) do
    lines =
      run
      |> Pipeline.list_run_events(order: :desc, limit: 60)
      |> Enum.map(&driving_line(&1.line))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim/1)

    doing = List.first(lines)

    %{
      doing: doing,
      verb: verb(doing),
      target: target(doing),
      url: Tools.get_browser_url(task) || Enum.find_value(lines, &opened/1),
      frame: frame(doing, task)
    }
  end

  # A browser this run has not touched yet has nothing to show.
  defp frame(nil, %Task{}), do: nil
  defp frame(_doing, %Task{} = task), do: Tools.get_browser_frame(task)

  # `browser_goto` is the only thing that says where the browser went, and the
  # newest one is where it is.
  defp opened("goto " <> url), do: url
  defp opened(_other), do: nil

  # The log line reads as an instruction - `click "Save"` - so the word it starts
  # with is what Rail did and the rest is what it did it to.
  defp verb(nil), do: "idle"
  defp verb(line), do: line |> String.split(" ", parts: 2) |> List.first()

  defp target(nil), do: @waiting
  defp target(line), do: line |> String.split(" ", parts: 2) |> Enum.at(1, "")
end

defmodule Rail.Pipeline.Utils.DrivingLine do
  @moduledoc """
  What a run's log line says Rail did, with the namespace taken off the front.

  `Rail.Mcp.Actions.CallRunTool` files everything it runs under the namespace of
  the tool that ran - `[browser]`, `[qa]`, `[demo]` - so a reader can tell
  driving the page apart from reporting on it. Three places read those lines back
  and all three want the same thing: whether this line is one of Rail's at all,
  and what it says with the prefix gone.

  The remainder is returned untrimmed, because the indent is meaning. Rail
  indents each step it actually took under the instruction it was given, and that
  is the whole of how the two are told apart.
  """

  @doc """
  Returns what `line` says with its namespace removed, or `nil` when the line is
  not one Rail wrote.
  """
  def driving_line("[browser] " <> rest), do: rest
  def driving_line("[qa] " <> rest), do: rest
  def driving_line("[demo] " <> rest), do: rest
  def driving_line(_other), do: nil
end

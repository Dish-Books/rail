defmodule Rail.Pipeline.Actions.ReadDemo do
  @moduledoc """
  Reads what a demo run said it filmed, out of its task's scratch directory.

  The demo owns `<scratch>/demo/<identifier>.json` and rewrites the whole of it
  every recording. What comes out of it is the agent's word rather than Rail's,
  so a file that is missing, blank or not the shape agreed reads as no demo at
  all - which is also what the panel shows before the first run has finished.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the demo `task`'s run wrote, or `nil` when there is none to read.

  Requires `issue` to be preloaded.
  """
  def read_demo(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "demo", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"summary" => summary} = demo} when is_binary(summary) <- Jason.decode(content) do
      %Demo{
        title: text(demo["title"]),
        summary: text(summary),
        not_shown: text(demo["not_shown"])
      }
    else
      _unreadable -> nil
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_other), do: nil
end

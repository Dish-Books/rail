defmodule Rail.Pipeline.Actions.ReadPlan do
  @moduledoc """
  Reads the implementation plan an architect run wrote into its task's scratch
  directory.

  The plan lives in scratch while it is being argued over, at
  `<scratch>/plans/<identifier>.md`. Approving it is what puts it anywhere else.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the plan `task`'s architect run wrote, or `nil` when there is none yet.

  A blank file is no plan: the agent has opened it but not written it. The plan is
  markdown as the architect left it. Requires `issue` to be preloaded.
  """
  def read_plan(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    case [scratch_path, "plans", "#{identifier}.md"] |> Path.join() |> File.read() do
      {:ok, content} -> if String.trim(content) == "", do: nil, else: content
      {:error, _unreadable} -> nil
    end
  end
end

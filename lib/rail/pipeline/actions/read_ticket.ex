defmodule Rail.Pipeline.Actions.ReadTicket do
  @moduledoc """
  Reads the ticket a product run wrote into its task's scratch directory.

  The ticket lives in scratch until a human approves it, at
  `<scratch>/tickets/<identifier>.md`.
  """

  import Rail.Pipeline.Utils.ParseTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the parsed ticket `task`'s product run wrote, or `nil` when there is none yet.

  A blank file is no ticket: the agent has opened it but not written it.
  Requires `issue` to be preloaded.
  """
  def read_ticket(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    case [scratch_path, "tickets", "#{identifier}.md"] |> Path.join() |> File.read() do
      {:ok, content} -> if String.trim(content) == "", do: nil, else: parse_ticket(content)
      {:error, _unreadable} -> nil
    end
  end
end

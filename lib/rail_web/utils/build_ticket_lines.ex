defmodule RailWeb.Utils.BuildTicketLines do
  @moduledoc """
  The lines of a saved ticket a reader reads and comments on: its title, priority and estimate, then its description's.
  """

  import RailWeb.Utils.BuildDocumentBlocks

  alias Rail.Issues.Schemas.Issue

  @doc """
  Returns `%{title:, priority:, estimate:, description:}` for `ticket`, the first three a line each and the last
  the description's lines as `build_document_blocks/1` makes them.
  """
  def build_ticket_lines(ticket) do
    priority = (ticket.priority && Issue.priority_label(ticket.priority)) || "No priority"

    estimate =
      case ticket.estimate do
        1 -> "1 Point"
        points when is_integer(points) -> "#{points} Points"
        nil -> "No estimate"
      end

    %{
      title: line(:title, ticket.title, "Title"),
      priority: line(:priority, priority, "Priority"),
      estimate: line(:estimate, estimate, "Estimate"),
      description: build_document_blocks(ticket.description || "")
    }
  end

  defp line(kind, text, label) do
    %{key: "#{kind}-#{:erlang.phash2({text, 1})}", kind: kind, text: text, occurrence: 1, label: label, depth: 0}
  end
end

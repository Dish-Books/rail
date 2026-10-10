defmodule Rail.Pipeline.Utils.TicketTrailer do
  @moduledoc """
  The line an agent ends each commit message with, naming the ticket the commit is for.
  """

  alias Rail.Issues.Schemas.Issue

  @doc "Returns the `Ticket:` trailer for `issue`, its URL included when it has one."
  def ticket_trailer(%Issue{identifier: identifier, url: url}) when is_binary(url) and url != "",
    do: "Ticket: #{identifier} #{url}"

  def ticket_trailer(%Issue{identifier: identifier}), do: "Ticket: #{identifier}"
end

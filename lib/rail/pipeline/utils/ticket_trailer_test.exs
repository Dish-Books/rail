defmodule Rail.Pipeline.Utils.TicketTrailerTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.TicketTrailer

  alias Rail.Issues.Schemas.Issue

  test "names the ticket, with its link when it has one" do
    assert ticket_trailer(%Issue{identifier: "TTR-1", url: "https://linear.app/rail/issue/TTR-1"}) ==
             "Ticket: TTR-1 https://linear.app/rail/issue/TTR-1"

    assert ticket_trailer(%Issue{identifier: "TTR-1", url: ""}) == "Ticket: TTR-1"
    assert ticket_trailer(%Issue{identifier: "TTR-1", url: nil}) == "Ticket: TTR-1"
  end
end

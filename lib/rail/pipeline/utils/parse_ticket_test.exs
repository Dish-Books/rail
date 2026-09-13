defmodule Rail.Pipeline.Utils.ParseTicketTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.ParseTicket

  test "reads title, priority and estimate out of front matter" do
    content = """
    ---
    title: Journal Entry shows attachments
    priority: high
    estimate: 3
    ---
    The problem paragraph.

    ## Desired outcome

    It works.
    """

    ticket = parse_ticket(content)

    assert ticket.title == "Journal Entry shows attachments"
    assert ticket.priority == :high
    assert ticket.estimate == 3
    assert ticket.description == "The problem paragraph.\n\n## Desired outcome\n\nIt works."
  end

  test "unquotes a title that needed quoting, and reads the priority by name" do
    ticket = parse_ticket("---\ntitle: \"Fix: the thing\"\npriority: Urgent\nestimate: 5\n---\nBody.")

    assert ticket.title == "Fix: the thing"
    assert ticket.priority == :urgent
    assert ticket.estimate == 5
  end

  test "a priority written as a number is not one we have" do
    assert is_nil(parse_ticket("---\ntitle: T\npriority: 1\n---\nBody.").priority)
  end

  test "a priority or estimate it cannot read is left unset rather than guessed" do
    ticket = parse_ticket("---\ntitle: Fix bug\npriority: whenever\nestimate: soon\n---\nBody.")

    assert ticket.title == "Fix bug"
    assert is_nil(ticket.priority)
    assert is_nil(ticket.estimate)
  end

  test "a ticket written in the older heading form is still read" do
    content = """
    # Update navigation header

    The header should show the project switcher.
    Additional notes here.
    """

    ticket = parse_ticket(content)

    assert ticket.title == "Update navigation header"

    assert ticket.description ==
             "The header should show the project switcher.\nAdditional notes here."

    assert is_nil(ticket.priority)
  end

  test "a ticket with no heading at all is all description" do
    ticket = parse_ticket("Just a raw prompt without title heading.")

    assert ticket.title == ""
    assert ticket.description == "Just a raw prompt without title heading."
  end

  test "an empty ticket file parses to an empty ticket" do
    assert %{title: "", description: ""} = parse_ticket(nil)
    assert %{title: "", description: ""} = parse_ticket("")
    assert %{title: "", description: ""} = parse_ticket("   \n\n  ")
  end
end

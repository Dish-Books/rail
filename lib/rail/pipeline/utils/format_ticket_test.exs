defmodule Rail.Pipeline.Utils.FormatTicketTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues.Schemas.Issue

  test "writes front matter and the description below it" do
    issue = %Issue{title: "Fix bug", description: "Details go here.", priority: :high, estimate: 3}

    assert format_ticket(issue) ==
             "---\ntitle: Fix bug\npriority: high\nestimate: 3\n---\n\nDetails go here.\n"
  end

  test "leaves out what the issue has nothing for" do
    assert format_ticket(%Issue{title: "Fix bug", description: "Details go here.", priority: nil}) ==
             "---\ntitle: Fix bug\n---\n\nDetails go here.\n"

    assert format_ticket(%Issue{title: "Fix bug", description: "", priority: nil}) ==
             "---\ntitle: Fix bug\n---\n"

    assert format_ticket(%Issue{title: "Fix bug", description: nil, priority: nil}) ==
             "---\ntitle: Fix bug\n---\n"
  end
end

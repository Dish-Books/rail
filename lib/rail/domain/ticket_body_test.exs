defmodule Rail.Domain.TicketBodyTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TicketBody

  test "changeset/2 validates required title" do
    valid_changeset = TicketBody.changeset(%TicketBody{}, %{title: "My Ticket", description: "Details"})
    assert valid_changeset.valid?

    invalid_changeset = TicketBody.changeset(%TicketBody{}, %{title: ""})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).title
  end

  test "factory/0 returns a valid struct" do
    ticket = TicketBody.factory()
    assert ticket.title == "Add user profile settings"
    assert ticket.description =~ "Users should be able to update their email"
  end

  test "parse/1 extracts title from first line starting with # and trims body" do
    content = """
    # Update navigation header

    The header should show the project switcher.
    Additional notes here.
    """

    ticket = TicketBody.parse(content)
    assert ticket.title == "Update navigation header"
    assert ticket.description == "The header should show the project switcher.\nAdditional notes here."
  end

  test "parse/1 handles nil and empty string" do
    assert %TicketBody{title: "", description: ""} = TicketBody.parse(nil)
    assert %TicketBody{title: "", description: ""} = TicketBody.parse("")
    assert %TicketBody{title: "", description: ""} = TicketBody.parse("   \n\n  ")
  end

  test "parse/1 handles markdown without a # heading line" do
    content = "Just a raw prompt without title heading."
    ticket = TicketBody.parse(content)
    assert ticket.title == ""
    assert ticket.description == "Just a raw prompt without title heading."
  end

  test "format/2 and format/1 serializes to markdown" do
    assert TicketBody.format("Fix bug", "Details go here.") == "# Fix bug\n\nDetails go here."
    assert TicketBody.format("Fix bug", "") == "# Fix bug"
    assert TicketBody.format("Fix bug", nil) == "# Fix bug"

    ticket = %TicketBody{title: "Fix bug", description: "Details go here."}
    assert TicketBody.format(ticket) == "# Fix bug\n\nDetails go here."
  end

  test "split/1 returns original body as ticket and nil plan when no plan heading exists" do
    body = "Fix the login button styling on mobile screens."
    result = TicketBody.split(body)
    assert result.ticket == "Fix the login button styling on mobile screens."
    assert is_nil(result.plan)
  end

  test "split/1 returns empty ticket and nil plan for empty string" do
    assert %{ticket: "", plan: nil} = TicketBody.split("")
  end

  test "split/1 splits on standard ## Implementation plan heading" do
    body = """
    We need to support multiple file uploads.

    ## Implementation plan

    1. Add upload endpoint
    2. Update UI with dropzone
    """

    result = TicketBody.split(body)
    assert result.ticket == "We need to support multiple file uploads."
    assert result.plan == "## Implementation plan\n\n1. Add upload endpoint\n2. Update UI with dropzone"
  end

  test "split/1 matches heading case-insensitively and with extra spaces" do
    body = """
    Feature request description.

    ##   Implementation Plan  

    Approach details.
    """

    result = TicketBody.split(body)
    assert result.ticket == "Feature request description."
    assert result.plan == "##   Implementation Plan  \n\nApproach details."
  end

  test "split/1 ignores ## Implementation plan inside fenced code blocks" do
    body = """
    Here is an example markdown document:

    ```markdown
    ## Implementation plan
    This is inside a code fence and should not split.
    ```

    And now the real plan:

    ## Implementation plan

    Real step 1.
    """

    result = TicketBody.split(body)
    assert result.ticket =~ "Here is an example markdown document:"
    assert result.ticket =~ "```markdown\n## Implementation plan"
    assert result.plan == "## Implementation plan\n\nReal step 1."
  end

  test "split/1 handles heading at the very start of the body" do
    body = "## Implementation plan\nOnly a plan here."
    result = TicketBody.split(body)
    assert result.ticket == ""
    assert result.plan == "## Implementation plan\nOnly a plan here."
  end

  test "split/1 returns nil plan if heading has no content after it" do
    body = """
    Ticket content here.

    ## Implementation plan
    """

    result = TicketBody.split(body)
    assert result.ticket == "Ticket content here."
    assert is_nil(result.plan)
  end

  test "acceptance_criteria/1 returns empty list when no criteria section exists or body is empty" do
    assert TicketBody.acceptance_criteria("") == []
    assert TicketBody.acceptance_criteria("Just a title and body") == []
  end

  test "acceptance_criteria/1 extracts top-level bullets, joins continuations, strips formatting, stops at next ##" do
    body = """
    # Ticket Title

    Some intro text.

    ## Acceptance criteria

    * A task reaches **Ready to merge** only once it has a demo or has declined one,
      and the human plays that demo from the task in one action.
    - The demo covers *acceptance criteria*,
      so the human can tell what is shown.
    * A change with `no visible behavior` says so in a line.

    ## Explicitly out of scope

    * Audio narration.
    """

    criteria = TicketBody.acceptance_criteria(body)
    assert length(criteria) == 3

    assert Enum.at(criteria, 0) ==
             "A task reaches Ready to merge only once it has a demo or has declined one, and the human plays that demo from the task in one action."

    assert Enum.at(criteria, 1) ==
             "The demo covers acceptance criteria, so the human can tell what is shown."

    assert Enum.at(criteria, 2) ==
             "A change with no visible behavior says so in a line."
  end

  test "acceptance_criteria/1 ignores bullets inside code fences" do
    body = """
    ## Acceptance criteria

    ```markdown
    * Not a real criterion
    - Also inside fence
    ```
    * Real criterion after fence
    """

    criteria = TicketBody.acceptance_criteria(body)
    assert criteria == ["Real criterion after fence"]
  end

  test "parse_splits/1 parses maps, tuple lists, and binary lists" do
    map_entries = %{
      "split-2.md" => "# Ticket 2\nSecond ticket body",
      "split-1.md" => "# Ticket 1\nFirst ticket body",
      "ignored.txt" => "Not a split file"
    }

    parsed = TicketBody.parse_splits(map_entries)
    assert length(parsed) == 2
    assert Enum.at(parsed, 0).title == "Ticket 1"
    assert Enum.at(parsed, 1).title == "Ticket 2"

    tuple_entries = [
      {"split-1.md", "# First\nBody 1"},
      {"split-2.md", "# Second\nBody 2"}
    ]

    parsed_tuples = TicketBody.parse_splits(tuple_entries)
    assert length(parsed_tuples) == 2
    assert Enum.at(parsed_tuples, 0).title == "First"

    binary_entries = [
      "# Alpha\nDesc A",
      "# Beta\nDesc B"
    ]

    parsed_binaries = TicketBody.parse_splits(binary_entries)
    assert length(parsed_binaries) == 2
    assert Enum.at(parsed_binaries, 0).title == "Alpha"

    assert TicketBody.parse_splits([123, 456]) == []
  end

  test "parse_split_files/1 parses sorted split files from a directory" do
    temp_dir = Path.join(System.tmp_dir!(), "split_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    File.write!(Path.join(temp_dir, "split-2.md"), "# Split 2\nBody 2")
    File.write!(Path.join(temp_dir, "split-1.md"), "# Split 1\nBody 1")
    File.write!(Path.join(temp_dir, "other.md"), "# Other\nBody other")

    assert {:ok, tickets} = TicketBody.parse_split_files(temp_dir)
    assert length(tickets) == 2
    assert Enum.at(tickets, 0).title == "Split 1"
    assert Enum.at(tickets, 1).title == "Split 2"

    assert {:error, :enoent} = TicketBody.parse_split_files("/non/existent/path/for/sure")
  end

  test "parse_manifest/1 parses JSON string, map manifests, and list manifests" do
    json = """
    {
      "splits": [
        {"title": "Split One", "description": "Desc One"},
        {"title": "Split Two"}
      ]
    }
    """

    tickets = TicketBody.parse_manifest(json)
    assert length(tickets) == 2
    assert Enum.at(tickets, 0).title == "Split One"
    assert Enum.at(tickets, 0).description == "Desc One"
    assert Enum.at(tickets, 1).title == "Split Two"
    assert Enum.at(tickets, 1).description == ""

    tickets_manifest = %{"tickets" => ["# Raw Ticket\nRaw description"]}
    parsed_tickets = TicketBody.parse_manifest(tickets_manifest)
    assert length(parsed_tickets) == 1
    assert Enum.at(parsed_tickets, 0).title == "Raw Ticket"

    test_doc = """
    ## Acceptance criteria

    * ***
    * Valid item
    """

    assert TicketBody.acceptance_criteria(test_doc) == ["Valid item"]

    content_map_list = [%{"content" => "# Subticket\nContent desc"}, %{"unknown" => true}, 123]
    parsed_content_maps = TicketBody.parse_manifest(content_map_list)
    assert length(parsed_content_maps) == 1
    assert Enum.at(parsed_content_maps, 0).title == "Subticket"

    assert TicketBody.parse_manifest("invalid json {") == []
    assert TicketBody.parse_manifest(12_345) == []
  end
end

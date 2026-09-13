defmodule Rail.Pipeline.Actions.ParseTranscriptTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Actions.ParseTranscript

  test "a log with nothing in it has no turns" do
    assert parse_transcript([]) == []
    assert parse_transcript(nil) == []
    assert parse_transcript("") == []
    assert parse_transcript("   \n   ") == []
    assert parse_transcript(["   ", "   "]) == []
  end

  test "reads a multiline string as lines" do
    assert length(parse_transcript("[human] Hello\n[run] claude\nAgent reply")) == 3
  end

  test "reads a one-line human comment" do
    [turn] = parse_transcript(["[human] Please change the title of this button."])

    assert turn.author == :human
    assert turn.content == "Please change the title of this button."
  end

  test "a single log entry holding newlines is still one comment" do
    [turn] = parse_transcript(["[human] Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."])

    assert turn.author == :human
    assert turn.content == "Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."
  end

  test "a comment runs on until the harness says otherwise" do
    logs = [
      "[human] Please address these points:",
      "- Item 1",
      "- Item 2",
      "[run] agy pid 4321 in /tmp",
      "I have addressed both items."
    ]

    [comment, event, reply] = parse_transcript(logs)

    assert comment.author == :human
    assert comment.content == "Please address these points:\n- Item 1\n- Item 2"

    assert event.author == :event
    assert event.content == "[run] agy pid 4321 in /tmp"

    assert reply.author == :role
    assert reply.content == "I have addressed both items."
  end

  test "consecutive prefixed human lines are one comment" do
    logs = [
      "[human] First paragraph line 1",
      "[human] First paragraph line 2",
      "[run] claude pid 1234 in /tmp"
    ]

    [comment, event] = parse_transcript(logs)

    assert comment.author == :human
    assert comment.content == "First paragraph line 1\nFirst paragraph line 2"
    assert event.author == :event
  end

  test "consecutive tool lines group into one activity block" do
    logs = [
      "Starting the task now.",
      "[tool] read_file path/to/file.dart",
      "[tool] grep_search query: foo",
      "[tool error] command failed",
      "Found the relevant lines. Editing now.",
      "[tool] edit_file path/to/file.dart",
      "All changes applied successfully."
    ]

    [prose, activity, more_prose, one_tool, closing] = parse_transcript(logs)

    assert prose.author == :role
    assert prose.content == "Starting the task now."

    assert activity.author == :activity

    assert activity.content ==
             "[tool] read_file path/to/file.dart\n[tool] grep_search query: foo\n[tool error] command failed"

    assert more_prose.author == :role
    assert more_prose.content == "Found the relevant lines. Editing now."

    assert one_tool.author == :activity
    assert one_tool.content == "[tool] edit_file path/to/file.dart"

    assert closing.author == :role
    assert closing.content == "All changes applied successfully."
  end

  test "reads the harness prefixes as events" do
    logs = [
      "[init] session 123 · 5 tools · 2 MCP servers",
      "[rail] Pull request #42 recorded.",
      "[result] success · 1.2K tokens",
      "[error] Something broke in the toolchain"
    ]

    turns = parse_transcript(logs)

    assert length(turns) == 4
    assert Enum.all?(turns, &(&1.author == :event))
  end

  test "markdown links and checklists are prose, not events" do
    logs = [
      "Here are the details:",
      "[Documentation link](https://example.com) explains the architecture.",
      "[x] Completed step 1",
      "[ ] Todo step 2"
    ]

    [turn] = parse_transcript(logs)

    assert turn.author == :role

    assert turn.content ==
             "Here are the details:\n" <>
               "[Documentation link](https://example.com) explains the architecture.\n" <>
               "[x] Completed step 1\n" <>
               "[ ] Todo step 2"
  end

  test "a mixed log reads as user, activity, agent and event turns" do
    logs = [
      "[human] User question",
      "[tool] run_check",
      "Agent response",
      "[rail] System event"
    ]

    turns = parse_transcript(logs)

    assert Enum.map(turns, & &1.author) == [:human, :activity, :role, :event]

    assert [%{content: "User question"}] = Enum.filter(turns, &(&1.author == :human))
    assert [%{content: "Agent response"}] = Enum.filter(turns, &(&1.author == :role))
  end
end

defmodule Rail.Pipeline.Actions.ParseTranscriptTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Turn

  test "a log with nothing in it has no turns" do
    assert Pipeline.parse_transcript([]) == []
    assert Pipeline.parse_transcript(nil) == []
    assert Pipeline.parse_transcript("") == []
    assert Pipeline.parse_transcript("   \n   ") == []
    assert Pipeline.parse_transcript(["   ", "   "]) == []
  end

  test "reads a multiline string as lines" do
    assert length(Pipeline.parse_transcript("[human] Hello\n[run] claude\nAgent reply")) == 3
  end

  test "reads a one-line human comment" do
    [turn] = Pipeline.parse_transcript(["[human] Please change the title of this button."])

    assert turn.author == :human
    assert turn.content == "Please change the title of this button."
  end

  test "a single log entry holding newlines is still one comment" do
    [turn] = Pipeline.parse_transcript(["[human] Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."])

    assert turn.author == :human
    assert turn.content == "Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."
  end

  test "a comment runs on until the harness says otherwise" do
    logs = [
      "[human] Please address these points:",
      "- Item 1",
      "- Item 2",
      "[run] claude pid 4321 in /tmp",
      "I have addressed both items."
    ]

    [comment, event, reply] = Pipeline.parse_transcript(logs)

    assert comment.author == :human
    assert comment.content == "Please address these points:\n- Item 1\n- Item 2"

    assert event.author == :event
    assert event.content == "[run] claude pid 4321 in /tmp"

    assert reply.author == :role
    assert reply.content == "I have addressed both items."
  end

  test "consecutive prefixed human lines are one comment" do
    logs = [
      "[human] First paragraph line 1",
      "[human] First paragraph line 2",
      "[run] claude pid 1234 in /tmp"
    ]

    [comment, event] = Pipeline.parse_transcript(logs)

    assert comment.author == :human
    assert comment.content == "First paragraph line 1\nFirst paragraph line 2"
    assert event.author == :event
  end

  # Everyone on a task reads the same conversation, so each message says whose it is.
  test "a human's lines carry who sent them, and two people's messages are two turns" do
    logs = [
      "[human:usr_dana] Please look again",
      "[human:usr_dana] at the header.",
      "[human:usr_omar] And the footer.",
      "[human] An older note."
    ]

    assert [
             %Turn{author: :human, sender_id: "usr_dana", content: "Please look again\nat the header."},
             %Turn{author: :human, sender_id: "usr_omar", content: "And the footer."},
             %Turn{author: :human, sender_id: nil, content: "An older note."}
           ] = Pipeline.parse_transcript(logs)
  end

  # Rail's own note to the agent reads as a message to it, not as something
  # the agent said, and the label says which of the reminders it was.
  test "consecutive reminder lines are one reminder, ending whatever came before" do
    logs = [
      "[human] Please look again",
      "[rail] 1 finding had no evidence, so the report went back to QA (1 of 2).",
      "[reminder 1 of 2] This report is not valid yet.",
      "[reminder 1 of 2]",
      "[reminder 1 of 2] - Export button stays enabled (export-button-enabled): no evidence attached.",
      "I attached a screenshot."
    ]

    assert [
             %Turn{author: :human, content: "Please look again"},
             %Turn{author: :event},
             %Turn{
               author: :reminder,
               label: "reminder 1 of 2",
               content:
                 "This report is not valid yet.\n\n- Export button stays enabled (export-button-enabled): no evidence attached."
             },
             %Turn{author: :role, content: "I attached a screenshot."}
           ] = Pipeline.parse_transcript(logs)

    assert [%Turn{author: :human}, %Turn{author: :reminder, label: "reminder 2 of 2", content: "Again."}] =
             Pipeline.parse_transcript(["[human] One", "more", "[reminder 2 of 2] Again."])

    assert [%Turn{label: "reminder 1 of 2", content: "First."}, %Turn{label: "reminder 2 of 2", content: "Second."}] =
             Pipeline.parse_transcript(["[reminder 1 of 2] First.", "[reminder 2 of 2] Second."])

    assert [%Turn{author: :reminder, label: "answered from past answers", content: "You asked: X?\nAnswered by Rail."}] =
             Pipeline.parse_transcript([
               "[answered from past answers] You asked: X?",
               "[answered from past answers] Answered by Rail."
             ])
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

    [prose, activity, more_prose, one_tool, closing] = Pipeline.parse_transcript(logs)

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

    turns = Pipeline.parse_transcript(logs)

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

    [turn] = Pipeline.parse_transcript(logs)

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

    turns = Pipeline.parse_transcript(logs)

    assert Enum.map(turns, & &1.author) == [:human, :activity, :role, :event]

    assert [%{content: "User question"}] = Enum.filter(turns, &(&1.author == :human))
    assert [%{content: "Agent response"}] = Enum.filter(turns, &(&1.author == :role))
  end
end

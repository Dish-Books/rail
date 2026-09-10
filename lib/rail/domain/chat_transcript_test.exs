defmodule Rail.Domain.ChatTranscriptTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.ChatTranscript
  alias Rail.Domain.ChatTurn
  alias Rail.Domain.HandoffLine

  test "changeset/2 and factory/0" do
    transcript = ChatTranscript.factory()
    assert ChatTranscript.count(transcript) == 1
    refute ChatTranscript.empty?(transcript)

    changeset = ChatTranscript.changeset(%ChatTranscript{}, %{turns: [%{role: :user, content: "hi"}]})
    assert changeset.valid?
    applied = apply_changes(changeset)
    assert length(applied.turns) == 1
    assert length(applied.messages) == 1

    sync_messages = ChatTranscript.changeset(%ChatTranscript{}, %{messages: [%{role: :agent, content: "ok"}]})
    assert sync_messages.valid?
    assert length(apply_changes(sync_messages).turns) == 1

    both_changeset =
      ChatTranscript.changeset(%ChatTranscript{}, %{
        turns: [%{role: :user, content: "hi"}],
        messages: [%{role: :user, content: "hi"}]
      })

    assert both_changeset.valid?
  end

  test "empty logs yield empty transcript" do
    assert ChatTranscript.empty?(ChatTranscript.parse([]))
    assert ChatTranscript.empty?(ChatTranscript.parse(nil))
    assert ChatTranscript.empty?(ChatTranscript.parse(""))
    assert ChatTranscript.empty?(ChatTranscript.parse("   \n   "))
    assert ChatTranscript.empty?(ChatTranscript.parse(["   ", "   "]))
    assert ChatTranscript.empty?(:other)
  end

  test "parses multiline string directly" do
    raw = "[human] Hello\n[run] claude\nAgent reply"
    transcript = ChatTranscript.parse(raw)
    assert length(transcript.turns) == 3
  end

  test "parses legacy one-line [human] comments" do
    logs = ["[human] Please change the title of this button."]
    transcript = ChatTranscript.parse(logs)

    assert length(transcript.messages) == 1
    msg = hd(transcript.messages)
    assert msg.author == :human
    assert msg.role == :user
    assert msg.text == "Please change the title of this button."
    assert ChatTurn.user?(msg)
  end

  test "handles legacy single log entry containing newlines" do
    logs = ["[human] Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."]
    transcript = ChatTranscript.parse(logs)

    assert length(transcript.messages) == 1
    msg = hd(transcript.messages)
    assert msg.author == :human
    assert msg.text == "Line 1 of feedback.\nLine 2 of feedback.\nLine 3 of feedback."
  end

  test "handles hydrated multi-line comments where only first line has [human]" do
    logs = [
      "[human] Please address these points:",
      "- Item 1",
      "- Item 2",
      "[run] agy pid 4321 in /tmp",
      "I have addressed both items."
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 3

    [first, second, third] = transcript.messages

    assert first.author == :human
    assert first.text == "Please address these points:\n- Item 1\n- Item 2"

    assert second.author == :event
    assert second.text == "[run] agy pid 4321 in /tmp"

    assert third.author == :role
    assert third.text == "I have addressed both items."
  end

  test "handles new-style [human] comments where every line is prefixed" do
    logs = [
      "[human] First paragraph line 1",
      "[human] First paragraph line 2",
      "[run] claude pid 1234 in /tmp"
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 2

    [msg0, msg1] = transcript.messages
    assert msg0.author == :human
    assert msg0.text == "First paragraph line 1\nFirst paragraph line 2"
    assert msg1.author == :event
  end

  test "groups interleaved [tool] runs into activity blocks" do
    logs = [
      "Starting the task now.",
      "[tool] read_file path/to/file.dart",
      "[tool] grep_search query: foo",
      "[tool error] command failed",
      "Found the relevant lines. Editing now.",
      "[tool] edit_file path/to/file.dart",
      "All changes applied successfully."
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 5

    [msg0, msg1, msg2, msg3, msg4] = transcript.messages

    # 1. Role prose
    assert msg0.author == :role
    assert msg0.text == "Starting the task now."

    # 2. Activity block (3 consecutive tool lines)
    assert msg1.author == :activity

    assert msg1.text ==
             "[tool] read_file path/to/file.dart\n[tool] grep_search query: foo\n[tool error] command failed"

    # 3. Role prose
    assert msg2.author == :role
    assert msg2.text == "Found the relevant lines. Editing now."

    # 4. Activity block (1 tool line)
    assert msg3.author == :activity
    assert msg3.text == "[tool] edit_file path/to/file.dart"

    # 5. Role prose
    assert msg4.author == :role
    assert msg4.text == "All changes applied successfully."
  end

  test "recognises HandoffLine, attaches subsequent note, and re-exposes roleId and summary" do
    logs = [
      "[handoff ← architect] From Architect: the implementation plan. Sent as this run's next turn:",
      "The plan details...",
      "Step 1: do something",
      "[handoff → reviewer] Handed to Reviewer: the reworked change."
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 2

    [first, second] = transcript.messages

    assert first.author == :event
    assert %HandoffLine{} = first.handoff
    assert first.handoff.role_id == "architect"
    assert first.handoff.direction == :received
    assert first.handoff.note == "The plan details...\nStep 1: do something"
    assert ChatTurn.handoff_role_id(first) == "architect"

    assert second.author == :event
    assert %HandoffLine{} = second.handoff
    assert second.handoff.role_id == "reviewer"
    assert second.handoff.direction == :sent
  end

  test "incoming handoff without note flushes cleanly" do
    logs = [
      "[handoff ← reviewer] Just summary",
      "[run] claude pid 123"
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.turns) == 2
    assert hd(transcript.turns).handoff.note == nil
  end

  test "handoff findings followed by agent run are not attributed as role prose" do
    logs = [
      "[handoff ← reviewer] From Reviewer: the findings from your last pass. Sent as this run's next turn:",
      "Findings from Reviewer on the change you just pushed (rework 1 of 3).",
      "Address every finding, nits included.",
      "[run] agy pid 12345 in /tmp/worktree",
      "[init] session 123 · 5 tools",
      "I am the engineer addressing the review findings."
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 4

    [handoff_msg, run_msg, init_msg, role_msg] = transcript.messages

    assert handoff_msg.author == :event

    assert handoff_msg.handoff.note ==
             "Findings from Reviewer on the change you just pushed (rework 1 of 3).\nAddress every finding, nits included."

    assert run_msg.author == :event
    assert run_msg.text =~ "[run]"

    assert init_msg.author == :event
    assert init_msg.text =~ "[init]"

    assert role_msg.author == :role
    assert role_msg.text == "I am the engineer addressing the review findings."
  end

  test "recognises [init], [result], [axis], and [error] as events" do
    logs = [
      "[init] session 123 · 5 tools · 2 MCP servers",
      "[axis] Pull request #42 recorded.",
      "[result] success · 1.2K tokens",
      "[error] Something broke in the toolchain"
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 4

    for msg <- transcript.messages do
      assert msg.author == :event
      assert ChatTurn.event?(msg)
    end
  end

  test "does not classify markdown links or checklists as events" do
    logs = [
      "Here are the details:",
      "[Documentation link](https://example.com) explains the architecture.",
      "[x] Completed step 1",
      "[ ] Todo step 2"
    ]

    transcript = ChatTranscript.parse(logs)
    assert length(transcript.messages) == 1
    assert hd(transcript.messages).author == :role

    assert hd(transcript.messages).text ==
             "Here are the details:\n" <>
               "[Documentation link](https://example.com) explains the architecture.\n" <>
               "[x] Completed step 1\n" <>
               "[ ] Todo step 2"
  end

  test "filters user_turns, agent_turns, and conversational_turns" do
    logs = [
      "[human] User question",
      "[tool] run_check",
      "Agent response",
      "[axis] System event"
    ]

    transcript = ChatTranscript.parse(logs)

    users = ChatTranscript.user_turns(transcript)
    assert length(users) == 1
    assert hd(users).content == "User question"

    agents = ChatTranscript.agent_turns(transcript)
    assert length(agents) == 1
    assert hd(agents).content == "Agent response"

    convs = ChatTranscript.conversational_turns(transcript)
    assert length(convs) == 2
  end

  test "to_markdown/1 and format_for_resumption/1 format cleanly" do
    logs = [
      "[human] First user question",
      "[tool] some_tool arg: 1",
      "Agent reply",
      "[axis] Event info"
    ]

    transcript = ChatTranscript.parse(logs)

    md = ChatTranscript.to_markdown(transcript)
    assert md =~ "### User\n\nFirst user question"
    assert md =~ "```\n[tool] some_tool arg: 1\n```"
    assert md =~ "### Assistant\n\nAgent reply"
    assert md =~ "> [axis] Event info"

    resumption = ChatTranscript.format_for_resumption(transcript)
    assert resumption == "[human] First user question\n\nAgent reply"
  end
end

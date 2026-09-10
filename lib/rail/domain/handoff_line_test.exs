defmodule Rail.Domain.HandoffLineTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.HandoffLine

  test "changeset/2 validates required fields" do
    valid_changeset =
      HandoffLine.changeset(%HandoffLine{}, %{
        role_id: "architect",
        summary: "Plan ready",
        direction: :received
      })

    assert valid_changeset.valid?

    invalid_changeset = HandoffLine.changeset(%HandoffLine{}, %{role_id: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).role_id
  end

  test "factory/0 returns a valid struct" do
    handoff = HandoffLine.factory()
    assert handoff.role_id == "architect"
    assert handoff.direction == :received
    assert handoff.summary =~ "Implementation plan"
    assert %DateTime{} = handoff.timestamp
  end

  test "from/2 and to/2 format lines" do
    assert HandoffLine.from("architect", "Implementation plan") ==
             "[handoff ← architect] Implementation plan"

    assert HandoffLine.to("reviewer", "Reworked changes") ==
             "[handoff → reviewer] Reworked changes"
  end

  test "format/1 serializes struct based on direction" do
    received = %HandoffLine{role_id: "architect", summary: "Plan", direction: :received}
    assert HandoffLine.format(received) == "[handoff ← architect] Plan"

    sent = %HandoffLine{role_id: "reviewer", summary: "Changes", direction: :sent}
    assert HandoffLine.format(sent) == "[handoff → reviewer] Changes"
  end

  test "parse/1 parses arrow syntax lines" do
    line1 = "[handoff ← architect] From Architect: the implementation plan. Sent as this run's next turn:"
    handoff1 = HandoffLine.parse(line1)
    assert handoff1.role_id == "architect"
    assert handoff1.direction == :received
    assert handoff1.summary == "From Architect: the implementation plan. Sent as this run's next turn:"
    assert is_nil(handoff1.note)

    line2 = "[handoff → reviewer] Handed to Reviewer: the reworked change."
    handoff2 = HandoffLine.parse(line2)
    assert handoff2.role_id == "reviewer"
    assert handoff2.direction == :sent
    assert handoff2.summary == "Handed to Reviewer: the reworked change."
  end

  test "parse/1 parses colon syntax and explicit direction syntax" do
    colon_line = "[handoff: engineer] Rework slice 2"
    h_colon = HandoffLine.parse(colon_line)
    assert h_colon.role_id == "engineer"
    assert h_colon.direction == :received
    assert h_colon.summary == "Rework slice 2"

    sent_line = "[handoff sent: qa] Review passed, starting QA"
    h_sent = HandoffLine.parse(sent_line)
    assert h_sent.role_id == "qa"
    assert h_sent.direction == :sent
    assert h_sent.summary == "Review passed, starting QA"

    recv_line = "[handoff received: qa_lead] QA report ready for grading"
    h_recv = HandoffLine.parse(recv_line)
    assert h_recv.role_id == "qa_lead"
    assert h_recv.direction == :received
    assert h_recv.summary == "QA report ready for grading"
  end

  test "parse/1 returns nil for non-matching lines" do
    assert is_nil(HandoffLine.parse(nil))
    assert is_nil(HandoffLine.parse(""))
    assert is_nil(HandoffLine.parse("Just ordinary text"))
    assert is_nil(HandoffLine.parse("[tool] read_file foo.ex"))
    assert is_nil(HandoffLine.parse("[init] session 123"))
  end

  test "helpers received?/1 and sent?/1" do
    received = %HandoffLine{direction: :received}
    sent = %HandoffLine{direction: :sent}

    assert HandoffLine.received?(received)
    refute HandoffLine.received?(sent)
    refute HandoffLine.received?(:other)

    assert HandoffLine.sent?(sent)
    refute HandoffLine.sent?(received)
    refute HandoffLine.sent?(:other)
  end
end

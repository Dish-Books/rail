defmodule Rail.Runs.Actions.ParseHandoffTest do
  use ExUnit.Case, async: true

  import Rail.Runs.Actions.ParseHandoff

  test "reads arrow syntax in both directions" do
    received =
      parse_handoff(
        "[handoff ← architect] From Architect: the implementation plan. Sent as this run's next turn:"
      )

    assert received.role_id == "architect"
    assert received.direction == :received

    assert received.summary ==
             "From Architect: the implementation plan. Sent as this run's next turn:"

    assert is_nil(received.note)

    sent = parse_handoff("[handoff → reviewer] Handed to Reviewer: the reworked change.")
    assert sent.role_id == "reviewer"
    assert sent.direction == :sent
    assert sent.summary == "Handed to Reviewer: the reworked change."
  end

  test "reads colon syntax as received" do
    handoff = parse_handoff("[handoff: engineer] Rework slice 2")

    assert handoff.role_id == "engineer"
    assert handoff.direction == :received
    assert handoff.summary == "Rework slice 2"
  end

  test "reads the direction when it is named" do
    sent = parse_handoff("[handoff sent: qa] Review passed, starting QA")
    assert sent.role_id == "qa"
    assert sent.direction == :sent
    assert sent.summary == "Review passed, starting QA"

    received = parse_handoff("[handoff received: qa_lead] QA report ready for grading")
    assert received.role_id == "qa_lead"
    assert received.direction == :received
    assert received.summary == "QA report ready for grading"
  end

  test "any other line is not a handoff" do
    assert is_nil(parse_handoff(nil))
    assert is_nil(parse_handoff(""))
    assert is_nil(parse_handoff("Just ordinary text"))
    assert is_nil(parse_handoff("[tool] read_file foo.ex"))
    assert is_nil(parse_handoff("[init] session 123"))
  end
end

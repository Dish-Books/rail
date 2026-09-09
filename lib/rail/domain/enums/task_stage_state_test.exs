defmodule Rail.Domain.Enums.TaskStageStateTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.TaskStageState

  test "all/0 and values/0 contain all 10 states" do
    expected = [
      :idle,
      :queued,
      :running,
      :paused_question,
      :paused_chat,
      :awaiting_approval,
      :changes_requested,
      :failed,
      :canceled,
      :blocked_rework
    ]

    assert TaskStageState.all() == expected
    assert TaskStageState.values() == expected
  end

  test "label/1 returns display labels" do
    assert TaskStageState.label(:idle) == "Idle"
    assert TaskStageState.label(:queued) == "Queued"
    assert TaskStageState.label(:running) == "Running"
    assert TaskStageState.label(:paused_question) == "Paused (Question)"
    assert TaskStageState.label(:paused_chat) == "Paused (Chat)"
    assert TaskStageState.label(:awaiting_approval) == "Awaiting approval"
    assert TaskStageState.label(:changes_requested) == "Changes requested"
    assert TaskStageState.label(:failed) == "Failed"
    assert TaskStageState.label(:canceled) == "Canceled"
    assert TaskStageState.label(:blocked_rework) == "Blocked rework"
    assert TaskStageState.label(:invalid) == nil
  end

  test "predicate helpers identify state categories" do
    assert TaskStageState.paused?(:paused_question)
    assert TaskStageState.paused?(:paused_chat)
    refute TaskStageState.paused?(:running)
    refute TaskStageState.paused?(:invalid)
    refute TaskStageState.paused?("paused_question")
    refute TaskStageState.paused?(nil)

    assert TaskStageState.terminal?(:failed)
    assert TaskStageState.terminal?(:canceled)
    refute TaskStageState.terminal?(:running)
    refute TaskStageState.terminal?(:invalid)
    refute TaskStageState.terminal?("failed")
    refute TaskStageState.terminal?(nil)

    assert TaskStageState.running?(:running)
    refute TaskStageState.running?(:queued)
    refute TaskStageState.running?(:invalid)
    refute TaskStageState.running?("running")

    assert TaskStageState.queued?(:queued)
    refute TaskStageState.queued?(:running)
    refute TaskStageState.queued?(:invalid)
    refute TaskStageState.queued?("queued")

    assert TaskStageState.awaiting_approval?(:awaiting_approval)
    refute TaskStageState.awaiting_approval?(:running)
    refute TaskStageState.awaiting_approval?(:invalid)
    refute TaskStageState.awaiting_approval?("awaiting_approval")

    assert TaskStageState.active?(:running)
    assert TaskStageState.active?(:paused_chat)
    refute TaskStageState.active?(:idle)
    refute TaskStageState.active?(:invalid)
    refute TaskStageState.active?("running")
    refute TaskStageState.active?(nil)
  end

  test "cast/1 and load/1 support camelCase strings" do
    assert TaskStageState.cast("awaiting_approval") == {:ok, :awaiting_approval}
    assert TaskStageState.cast("awaitingApproval") == {:ok, :awaiting_approval}
    assert TaskStageState.cast("pausedQuestion") == {:ok, :paused_question}
    assert TaskStageState.cast("blockedRework") == {:ok, :blocked_rework}

    assert TaskStageState.dump(:awaiting_approval) == {:ok, "awaiting_approval"}
    assert TaskStageState.load("awaitingApproval") == {:ok, :awaiting_approval}
  end
end

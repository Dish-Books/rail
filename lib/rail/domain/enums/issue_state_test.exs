defmodule Rail.Domain.Enums.IssueStateTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.IssueState

  test "all/0 and values/0 contain all 5 states" do
    expected = [:triage, :backlog, :in_progress, :done, :canceled]
    assert IssueState.all() == expected
    assert IssueState.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert IssueState.label(:triage) == "Triage"
    assert IssueState.label(:backlog) == "Backlog"
    assert IssueState.label(:in_progress) == "In Progress"
    assert IssueState.label(:done) == "Done"
    assert IssueState.label(:canceled) == "Canceled"
    assert IssueState.label(:invalid) == nil
  end

  test "finished?/1, closed?/1 and active?/1 predicates" do
    assert IssueState.finished?(:done)
    assert IssueState.finished?(:canceled)
    assert IssueState.closed?(:done)
    assert IssueState.closed?(:canceled)
    refute IssueState.finished?(:in_progress)
    refute IssueState.finished?(:invalid)
    refute IssueState.finished?("done")
    refute IssueState.finished?(nil)

    assert IssueState.active?(:triage)
    assert IssueState.active?(:backlog)
    assert IssueState.active?(:in_progress)
    refute IssueState.active?(:done)
    refute IssueState.active?(:canceled)
    refute IssueState.active?(:invalid)
    refute IssueState.active?("in_progress")
    refute IssueState.active?(nil)
  end

  test "cast and dump handle camelCase strings" do
    assert IssueState.cast("inProgress") == {:ok, :in_progress}
    assert IssueState.cast("in_progress") == {:ok, :in_progress}
    assert IssueState.dump(:in_progress) == {:ok, "in_progress"}
    assert IssueState.load("inProgress") == {:ok, :in_progress}
  end
end

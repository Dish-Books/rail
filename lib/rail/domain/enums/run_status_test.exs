defmodule Rail.Domain.Enums.RunStatusTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.RunStatus

  test "all/0 and values/0 contain all 5 statuses" do
    expected = [:starting, :running, :finished, :adopted_dead, :blocked_on_input]
    assert RunStatus.all() == expected
    assert RunStatus.values() == expected
  end

  test "label/1 returns correct labels" do
    assert RunStatus.label(:starting) == "Starting"
    assert RunStatus.label(:running) == "Running"
    assert RunStatus.label(:finished) == "Finished"
    assert RunStatus.label(:adopted_dead) == "Adopted dead"
    assert RunStatus.label(:blocked_on_input) == "Blocked on input"
    assert RunStatus.label(:invalid) == nil
  end

  test "terminal?/1 and live?/1 categorize statuses" do
    assert RunStatus.terminal?(:finished)
    assert RunStatus.terminal?(:adopted_dead)
    refute RunStatus.terminal?(:running)
    refute RunStatus.terminal?(:blocked_on_input)
    refute RunStatus.terminal?(:invalid)
    refute RunStatus.terminal?("finished")
    refute RunStatus.terminal?(nil)

    assert RunStatus.live?(:starting)
    assert RunStatus.live?(:running)
    refute RunStatus.live?(:finished)
    refute RunStatus.live?(:blocked_on_input)
    refute RunStatus.live?(:invalid)
    refute RunStatus.live?("running")
    refute RunStatus.live?(nil)
  end

  test "cast and dump handle adopted_dead and blocked_on_input" do
    assert RunStatus.cast("adoptedDead") == {:ok, :adopted_dead}
    assert RunStatus.cast("adopted_dead") == {:ok, :adopted_dead}
    assert RunStatus.cast("blockedOnInput") == {:ok, :blocked_on_input}
    assert RunStatus.cast("blocked_on_input") == {:ok, :blocked_on_input}
    assert RunStatus.dump(:adopted_dead) == {:ok, "adopted_dead"}
    assert RunStatus.dump(:blocked_on_input) == {:ok, "blocked_on_input"}
    assert RunStatus.load("adoptedDead") == {:ok, :adopted_dead}
    assert RunStatus.load("blockedOnInput") == {:ok, :blocked_on_input}
  end
end

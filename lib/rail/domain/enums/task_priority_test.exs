defmodule Rail.Domain.Enums.TaskPriorityTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.TaskPriority

  test "all/0 and values/0 contain all 4 priorities" do
    expected = [:urgent, :high, :medium, :low]
    assert TaskPriority.all() == expected
    assert TaskPriority.values() == expected
  end

  test "valid?/1 verifies priorities correctly" do
    assert TaskPriority.valid?(:urgent)
    assert TaskPriority.valid?(:high)
    assert TaskPriority.valid?(:medium)
    assert TaskPriority.valid?(:low)
    refute TaskPriority.valid?(:invalid)
    assert TaskPriority.valid?("urgent")
    assert TaskPriority.valid?("high")
    refute TaskPriority.valid?("invalid")
    refute TaskPriority.valid?(nil)
  end

  test "label/1 returns correct display labels" do
    assert TaskPriority.label(:urgent) == "Urgent"
    assert TaskPriority.label(:high) == "High"
    assert TaskPriority.label(:medium) == "Medium"
    assert TaskPriority.label(:low) == "Low"
    assert TaskPriority.label("urgent") == "Urgent"
    assert TaskPriority.label("invalid") == nil
    assert TaskPriority.label(:invalid) == nil
    assert TaskPriority.label(nil) == nil
  end

  test "cast, dump and load handle strings and atoms" do
    assert TaskPriority.cast("urgent") == {:ok, :urgent}
    assert TaskPriority.cast(:urgent) == {:ok, :urgent}
    assert TaskPriority.cast("invalid") == :error
    assert TaskPriority.dump(:high) == {:ok, "high"}
    assert TaskPriority.dump("high") == {:ok, "high"}
    assert TaskPriority.dump(:invalid) == :error
    assert TaskPriority.load("medium") == {:ok, :medium}
    assert TaskPriority.load(:medium) == {:ok, :medium}
    assert TaskPriority.load("invalid") == :error
  end
end

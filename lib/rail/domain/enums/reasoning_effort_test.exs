defmodule Rail.Domain.Enums.ReasoningEffortTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.ReasoningEffort

  test "all/0 and values/0 contain low, medium, high" do
    expected = [:low, :medium, :high]
    assert ReasoningEffort.all() == expected
    assert ReasoningEffort.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert ReasoningEffort.label(:low) == "Low"
    assert ReasoningEffort.label(:medium) == "Medium"
    assert ReasoningEffort.label(:high) == "High"
    assert ReasoningEffort.label(:invalid) == nil
  end

  test "predicates test effort level" do
    assert ReasoningEffort.low?(:low)
    refute ReasoningEffort.low?(:medium)
    refute ReasoningEffort.low?(:invalid)

    assert ReasoningEffort.medium?(:medium)
    refute ReasoningEffort.medium?(:high)
    refute ReasoningEffort.medium?(:invalid)

    assert ReasoningEffort.high?(:high)
    refute ReasoningEffort.high?(:low)
    refute ReasoningEffort.high?(:invalid)
  end

  test "cast and dump work as expected" do
    assert ReasoningEffort.cast("low") == {:ok, :low}
    assert ReasoningEffort.cast("medium") == {:ok, :medium}
    assert ReasoningEffort.cast("high") == {:ok, :high}
    assert ReasoningEffort.dump(:high) == {:ok, "high"}
    assert ReasoningEffort.load("medium") == {:ok, :medium}
  end
end

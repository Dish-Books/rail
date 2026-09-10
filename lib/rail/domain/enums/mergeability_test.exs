defmodule Rail.Domain.Enums.MergeabilityTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.Mergeability

  test "all/0 and values/0 contain mergeable, conflicting, unknown" do
    expected = [:mergeable, :conflicting, :unknown]
    assert Mergeability.all() == expected
    assert Mergeability.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert Mergeability.label(:mergeable) == "Mergeable"
    assert Mergeability.label(:conflicting) == "Conflicting"
    assert Mergeability.label(:unknown) == "Unknown"
    assert Mergeability.label(:invalid) == nil
  end

  test "predicates identify mergeability state" do
    assert Mergeability.conflicting?(:conflicting)
    refute Mergeability.conflicting?(:mergeable)
    refute Mergeability.conflicting?(:invalid)

    assert Mergeability.mergeable?(:mergeable)
    refute Mergeability.mergeable?(:conflicting)
    refute Mergeability.mergeable?(:invalid)

    assert Mergeability.unknown?(:unknown)
    refute Mergeability.unknown?(:mergeable)
    refute Mergeability.unknown?(:invalid)
  end

  test "parse/1 parses GitHub status strings" do
    assert Mergeability.parse("MERGEABLE") == :mergeable
    assert Mergeability.parse("mergeable") == :mergeable
    assert Mergeability.parse("  CONFLICTING  ") == :conflicting
    assert Mergeability.parse("conflicting") == :conflicting
    assert Mergeability.parse("UNKNOWN") == :unknown
    assert Mergeability.parse("") == :unknown
    assert Mergeability.parse(nil) == :unknown
    assert Mergeability.parse(123) == :unknown
  end

  test "cast and dump work as expected" do
    assert Mergeability.cast("mergeable") == {:ok, :mergeable}
    assert Mergeability.cast("conflicting") == {:ok, :conflicting}
    assert Mergeability.dump(:mergeable) == {:ok, "mergeable"}
    assert Mergeability.load("unknown") == {:ok, :unknown}
  end
end

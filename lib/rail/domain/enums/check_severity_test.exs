defmodule Rail.Domain.Enums.CheckSeverityTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.CheckSeverity

  test "all/0 and values/0 contain all 5 severities" do
    expected = [:blocker, :critical, :major, :minor, :cosmetic]
    assert CheckSeverity.all() == expected
    assert CheckSeverity.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert CheckSeverity.label(:blocker) == "Blocker"
    assert CheckSeverity.label(:critical) == "Critical"
    assert CheckSeverity.label(:major) == "Major"
    assert CheckSeverity.label(:minor) == "Minor"
    assert CheckSeverity.label(:cosmetic) == "Cosmetic"
    assert CheckSeverity.label(:invalid) == nil
  end

  test "blocking?/1, blocker?/1 and critical?/1 predicates" do
    assert CheckSeverity.blocking?(:blocker)
    assert CheckSeverity.blocking?(:critical)
    refute CheckSeverity.blocking?(:major)
    refute CheckSeverity.blocking?(:minor)
    refute CheckSeverity.blocking?(:cosmetic)
    refute CheckSeverity.blocking?(:invalid)
    refute CheckSeverity.blocking?("blocker")
    refute CheckSeverity.blocking?(nil)

    assert CheckSeverity.blocker?(:blocker)
    refute CheckSeverity.blocker?(:critical)
    refute CheckSeverity.blocker?(:invalid)
    refute CheckSeverity.blocker?("blocker")
    refute CheckSeverity.blocker?(nil)

    assert CheckSeverity.critical?(:critical)
    refute CheckSeverity.critical?(:blocker)
    refute CheckSeverity.critical?(:invalid)
    refute CheckSeverity.critical?("critical")
    refute CheckSeverity.critical?(nil)
  end

  test "cast and dump work as expected" do
    assert CheckSeverity.cast("blocker") == {:ok, :blocker}
    assert CheckSeverity.cast("critical") == {:ok, :critical}
    assert CheckSeverity.dump(:major) == {:ok, "major"}
    assert CheckSeverity.load("minor") == {:ok, :minor}
  end
end

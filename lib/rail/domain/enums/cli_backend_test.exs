defmodule Rail.Domain.Enums.CliBackendTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.CliBackend

  test "all/0 and values/0 contain claude and agy" do
    expected = [:claude, :agy]
    assert CliBackend.all() == expected
    assert CliBackend.values() == expected
  end

  test "label/1 returns display labels" do
    assert CliBackend.label(:claude) == "Claude"
    assert CliBackend.label(:agy) == "Antigravity"
    assert CliBackend.label(:invalid) == nil
  end

  test "claude?/1 and agy?/1 predicates" do
    assert CliBackend.claude?(:claude)
    refute CliBackend.claude?(:agy)
    refute CliBackend.claude?(:invalid)

    assert CliBackend.agy?(:agy)
    refute CliBackend.agy?(:claude)
    refute CliBackend.agy?(:invalid)
  end

  test "cast and dump work as expected" do
    assert CliBackend.cast("claude") == {:ok, :claude}
    assert CliBackend.cast("agy") == {:ok, :agy}
    assert CliBackend.dump(:claude) == {:ok, "claude"}
    assert CliBackend.load("agy") == {:ok, :agy}
  end
end

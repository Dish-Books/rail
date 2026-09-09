defmodule Rail.Domain.Enums.CheckResultTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.CheckResult

  test "all/0 and values/0 contain pass, fail, warn, skip" do
    expected = [:pass, :fail, :warn, :skip]
    assert CheckResult.all() == expected
    assert CheckResult.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert CheckResult.label(:pass) == "Pass"
    assert CheckResult.label(:fail) == "Fail"
    assert CheckResult.label(:warn) == "Warn"
    assert CheckResult.label(:skip) == "Skip"
    assert CheckResult.label(:invalid) == nil
  end

  test "predicates test check result" do
    assert CheckResult.pass?(:pass)
    refute CheckResult.pass?(:fail)
    refute CheckResult.pass?(:invalid)

    assert CheckResult.fail?(:fail)
    refute CheckResult.fail?(:pass)
    refute CheckResult.fail?(:invalid)

    assert CheckResult.warn?(:warn)
    refute CheckResult.warn?(:pass)
    refute CheckResult.warn?(:invalid)

    assert CheckResult.skip?(:skip)
    refute CheckResult.skip?(:pass)
    refute CheckResult.skip?(:invalid)
  end

  test "cast and dump work as expected" do
    assert CheckResult.cast("pass") == {:ok, :pass}
    assert CheckResult.cast("fail") == {:ok, :fail}
    assert CheckResult.dump(:warn) == {:ok, "warn"}
    assert CheckResult.load("skip") == {:ok, :skip}
  end
end

defmodule Rail.Types.CpusTest do
  use ExUnit.Case, async: true

  alias Rail.Types.Cpus

  test "is stored as a float" do
    assert Cpus.type() == :float
    assert {:ok, 2.0} = Cpus.dump(2)
    assert {:ok, 0.5} = Cpus.dump(0.5)
    assert :error = Cpus.dump("2")
  end

  test "casts a number or what a form posts, a whole one as an integer" do
    assert {:ok, 2} = Cpus.cast(2)
    assert {:ok, 2} = Cpus.cast(2.0)
    assert {:ok, 0.5} = Cpus.cast(0.5)
    assert {:ok, 2} = Cpus.cast("2")
    assert {:ok, 1.25} = Cpus.cast(" 1.25 ")
    assert :error = Cpus.cast("two")
    assert :error = Cpus.cast("")
    assert :error = Cpus.cast(:two)
  end

  test "loads a whole reservation as an integer and part of one as a float" do
    assert {:ok, 1} = Cpus.load(1.0)
    assert {:ok, 0.75} = Cpus.load(0.75)
    assert :error = Cpus.load("1")
  end
end

defmodule Rail.Domain.Enums.TypeTest do
  use Rail.DataCase, async: true

  defmodule DummyEnum do
    @moduledoc false
    use Rail.Domain.Enums.Type,
      values: [:first_step, :second_step, :custom_step],
      labels: %{
        first_step: "1st Step",
        second_step: "2nd Step"
      }
  end

  test "all/0 and values/0 return all values in order" do
    assert DummyEnum.all() == [:first_step, :second_step, :custom_step]
    assert DummyEnum.values() == [:first_step, :second_step, :custom_step]
  end

  test "valid?/1 validates atoms, strings, and rejects invalid inputs" do
    assert DummyEnum.valid?(:first_step)
    assert DummyEnum.valid?(:second_step)
    refute DummyEnum.valid?(:unknown)

    assert DummyEnum.valid?("first_step")
    assert DummyEnum.valid?("firstStep")
    assert DummyEnum.valid?("first-step")
    refute DummyEnum.valid?("unknown")
    refute DummyEnum.valid?(nil)
    refute DummyEnum.valid?(123)
  end

  test "label/1 returns configured labels and defaults for unconfigured values" do
    assert DummyEnum.label(:first_step) == "1st Step"
    assert DummyEnum.label(:second_step) == "2nd Step"
    assert DummyEnum.label(:custom_step) == "Custom step"
    assert DummyEnum.label("first_step") == "1st Step"
    assert DummyEnum.label("firstStep") == "1st Step"

    assert DummyEnum.label(nil) == nil
    assert DummyEnum.label(:unknown) == nil
    assert DummyEnum.label("unknown") == nil
    assert DummyEnum.label(123) == nil
  end

  test "type/0 returns :string" do
    assert DummyEnum.type() == :string
  end

  test "cast/1 casts nil, atoms, strings, and rejects invalid terms" do
    assert DummyEnum.cast(nil) == {:ok, nil}
    assert DummyEnum.cast(:first_step) == {:ok, :first_step}
    assert DummyEnum.cast(:unknown) == :error

    assert DummyEnum.cast("first_step") == {:ok, :first_step}
    assert DummyEnum.cast("firstStep") == {:ok, :first_step}
    assert DummyEnum.cast("first-step") == {:ok, :first_step}
    assert DummyEnum.cast(" FIRST_STEP ") == {:ok, :first_step}
    assert DummyEnum.cast("invalid") == :error

    assert DummyEnum.cast(123) == :error
  end

  test "dump/1 dumps nil, atoms, strings, and rejects invalid terms" do
    assert DummyEnum.dump(nil) == {:ok, nil}
    assert DummyEnum.dump(:first_step) == {:ok, "first_step"}
    assert DummyEnum.dump(:unknown) == :error

    assert DummyEnum.dump("first_step") == {:ok, "first_step"}
    assert DummyEnum.dump("firstStep") == {:ok, "first_step"}
    assert DummyEnum.dump("invalid") == :error

    assert DummyEnum.dump(123) == :error
  end

  test "load/1 loads nil, strings, atoms, and rejects invalid terms" do
    assert DummyEnum.load(nil) == {:ok, nil}
    assert DummyEnum.load("first_step") == {:ok, :first_step}
    assert DummyEnum.load("firstStep") == {:ok, :first_step}
    assert DummyEnum.load("invalid") == :error

    assert DummyEnum.load(:first_step) == {:ok, :first_step}
    assert DummyEnum.load(:unknown) == :error

    assert DummyEnum.load(123) == :error
  end

  test "embed_as/1 returns :self and equal?/2 compares equality" do
    assert DummyEnum.embed_as(:json) == :self
    assert DummyEnum.equal?(:first_step, :first_step)
    refute DummyEnum.equal?(:first_step, :second_step)
  end
end

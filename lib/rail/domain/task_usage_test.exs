defmodule Rail.Domain.TaskUsageTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage

  test "factory/0 builds a valid struct" do
    usage = TaskUsage.factory()

    assert usage.input_tokens == 1_000
    assert usage.output_tokens == 500
    assert usage.cache_read_input_tokens == 200
    assert usage.cache_creation_input_tokens == 100
    assert Decimal.equal?(usage.total_cost, Decimal.new("0.025"))
    assert usage.currency == "USD"
  end

  test "zero/0 and zero?/1" do
    zero = TaskUsage.zero()
    assert TaskUsage.zero?(zero)
    assert zero.input_tokens == 0
    assert zero.output_tokens == 0
    assert zero.cache_read_input_tokens == 0
    assert zero.cache_creation_input_tokens == 0
    assert Decimal.equal?(zero.total_cost, 0)

    empty_with_nil_cost = %TaskUsage{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      total_cost: nil
    }

    assert TaskUsage.zero?(empty_with_nil_cost)

    non_zero = %TaskUsage{input_tokens: 1}
    refute TaskUsage.zero?(non_zero)

    cost_only = %TaskUsage{total_cost: Decimal.new("1.0")}
    refute TaskUsage.zero?(cost_only)
  end

  test "total_tokens/1 sums all 4 token categories" do
    usage = %TaskUsage{
      input_tokens: 100,
      output_tokens: 50,
      cache_read_input_tokens: 20,
      cache_creation_input_tokens: 10
    }

    assert TaskUsage.total_tokens(usage) == 180

    assert TaskUsage.total_tokens(%TaskUsage{}) == 0
  end

  test "add/2 aggregates tokens and handles cost combinations" do
    u1 = %TaskUsage{
      input_tokens: 100,
      output_tokens: 50,
      cache_read_input_tokens: 20,
      cache_creation_input_tokens: 10,
      total_cost: Decimal.new("0.01"),
      currency: "USD"
    }

    u2 = %TaskUsage{
      input_tokens: 200,
      output_tokens: 100,
      cache_read_input_tokens: 40,
      cache_creation_input_tokens: 20,
      total_cost: Decimal.new("0.02"),
      currency: "USD"
    }

    combined = TaskUsage.add(u1, u2)
    assert combined.input_tokens == 300
    assert combined.output_tokens == 150
    assert combined.cache_read_input_tokens == 60
    assert combined.cache_creation_input_tokens == 30
    assert Decimal.equal?(combined.total_cost, Decimal.new("0.03"))
    assert combined.currency == "USD"

    # Both costs nil
    u_nil1 = %TaskUsage{input_tokens: 10, total_cost: nil}
    u_nil2 = %TaskUsage{input_tokens: 20, total_cost: nil}
    assert TaskUsage.add(u_nil1, u_nil2).total_cost == nil

    # One cost nil
    u_with_cost = %TaskUsage{total_cost: Decimal.new("0.05")}
    assert Decimal.equal?(TaskUsage.add(u_nil1, u_with_cost).total_cost, Decimal.new("0.05"))
    assert Decimal.equal?(TaskUsage.add(u_with_cost, u_nil1).total_cost, Decimal.new("0.05"))

    # Currency fallback
    u_curr = %TaskUsage{currency: nil}
    assert TaskUsage.add(u_curr, %TaskUsage{currency: "EUR"}).currency == "EUR"
    assert TaskUsage.add(%TaskUsage{currency: nil}, %TaskUsage{currency: nil}).currency == "USD"

    # Numeric and string cost conversion in add/2
    u_int = %TaskUsage{total_cost: 1}
    u_float = %TaskUsage{total_cost: 0.5}
    u_str = %TaskUsage{total_cost: "0.25"}
    assert Decimal.equal?(TaskUsage.add(u_int, u_float).total_cost, Decimal.new("1.5"))
    assert Decimal.equal?(TaskUsage.add(u_str, u_int).total_cost, Decimal.new("1.25"))
  end

  test "describe/1 formats tokens and cost" do
    u_small = %TaskUsage{input_tokens: 500, total_cost: nil}
    assert TaskUsage.describe(u_small) == "500 tokens"

    u_k = %TaskUsage{input_tokens: 1_500, total_cost: Decimal.new("0.0050"), currency: "USD"}
    assert TaskUsage.describe(u_k) == "1.5K tokens · $0.0050"

    u_m = %TaskUsage{
      input_tokens: 2_500_000,
      total_cost: Decimal.new("12.3456"),
      currency: "EUR"
    }

    assert TaskUsage.describe(u_m) == "2.5M tokens · 12.3456 EUR"
  end

  test "changeset/2 validates constraints" do
    valid_attrs = %{
      "input_tokens" => 100,
      "output_tokens" => 50,
      "cache_read_input_tokens" => 25,
      "cache_creation_input_tokens" => 10,
      "total_cost" => "0.015",
      "currency" => "USD"
    }

    changeset = TaskUsage.changeset(%TaskUsage{}, valid_attrs)
    assert changeset.valid?
    assert Decimal.equal?(Ecto.Changeset.get_change(changeset, :total_cost), Decimal.new("0.015"))

    nil_cost_changeset = TaskUsage.changeset(%TaskUsage{}, %{"input_tokens" => 50})
    assert nil_cost_changeset.valid?
    assert Ecto.Changeset.get_field(nil_cost_changeset, :total_cost) == nil

    invalid_attrs = %{
      "input_tokens" => -1,
      "output_tokens" => -1,
      "cache_read_input_tokens" => -1,
      "cache_creation_input_tokens" => -1,
      "total_cost" => "-0.50"
    }

    invalid_changeset = TaskUsage.changeset(%TaskUsage{}, invalid_attrs)
    refute invalid_changeset.valid?

    assert %{
             input_tokens: ["must be greater than or equal to 0"],
             output_tokens: ["must be greater than or equal to 0"],
             cache_read_input_tokens: ["must be greater than or equal to 0"],
             cache_creation_input_tokens: ["must be greater than or equal to 0"],
             total_cost: ["must be greater than or equal to 0"]
           } = errors_on(invalid_changeset)
  end

  test "serializes to JSON via Jason" do
    usage = TaskUsage.factory()
    assert {:ok, json} = Jason.encode(usage)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["input_tokens"] == 1_000
    assert decoded["output_tokens"] == 500
  end
end

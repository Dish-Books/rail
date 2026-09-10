defmodule Rail.Domain.TaskUsage do
  @moduledoc """
  Token and cost accounting for an agent run or task.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_input_tokens, :integer, default: 0
    field :cache_creation_input_tokens, :integer, default: 0
    field :total_cost, :decimal
    field :currency, :string, default: "USD"
  end

  @fields [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :total_cost,
    :currency
  ]

  @doc "Builds a changeset for task usage attributes."
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, @fields)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_read_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_creation_input_tokens, greater_than_or_equal_to: 0)
    |> validate_non_negative_cost()
  end

  @doc "Returns a TaskUsage struct with all counters set to zero."
  def zero do
    %__MODULE__{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      total_cost: Decimal.new("0.0"),
      currency: "USD"
    }
  end

  @doc "Builds a valid TaskUsage struct fixture for testing."
  def factory do
    %__MODULE__{
      input_tokens: 1_000,
      output_tokens: 500,
      cache_read_input_tokens: 200,
      cache_creation_input_tokens: 100,
      total_cost: Decimal.new("0.025"),
      currency: "USD"
    }
  end

  @doc "Returns true if all token counters are 0 and total cost is nil or 0."
  def zero?(%__MODULE__{} = usage) do
    total_tokens(usage) == 0 and (is_nil(usage.total_cost) or Decimal.equal?(usage.total_cost, 0))
  end

  @doc "Returns the sum of all input, output, and cache tokens."
  def total_tokens(%__MODULE__{} = usage) do
    (usage.input_tokens || 0) +
      (usage.output_tokens || 0) +
      (usage.cache_read_input_tokens || 0) +
      (usage.cache_creation_input_tokens || 0)
  end

  @doc "Sums two TaskUsage structs field-wise."
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    total_cost =
      case {a.total_cost, b.total_cost} do
        {nil, nil} -> nil
        {cost_a, nil} -> to_decimal(cost_a)
        {nil, cost_b} -> to_decimal(cost_b)
        {cost_a, cost_b} -> Decimal.add(to_decimal(cost_a), to_decimal(cost_b))
      end

    %__MODULE__{
      input_tokens: (a.input_tokens || 0) + (b.input_tokens || 0),
      output_tokens: (a.output_tokens || 0) + (b.output_tokens || 0),
      cache_read_input_tokens: (a.cache_read_input_tokens || 0) + (b.cache_read_input_tokens || 0),
      cache_creation_input_tokens: (a.cache_creation_input_tokens || 0) + (b.cache_creation_input_tokens || 0),
      total_cost: total_cost,
      currency: a.currency || b.currency || "USD"
    }
  end

  @doc "Formats token and cost figures into a concise human-readable string."
  def describe(%__MODULE__{} = usage) do
    total = total_tokens(usage)
    compact = compact_number(total)
    tokens_part = "#{compact} tokens"

    case usage.total_cost do
      %Decimal{} = cost ->
        currency = usage.currency || "USD"
        formatted_cost = format_cost(cost, currency)
        "#{tokens_part} · #{formatted_cost}"

      nil ->
        tokens_part
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n) or is_float(n), do: Decimal.new("#{n}")
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp validate_non_negative_cost(changeset) do
    case get_field(changeset, :total_cost) do
      %Decimal{} = cost ->
        if Decimal.compare(cost, 0) == :lt do
          add_error(changeset, :total_cost, "must be greater than or equal to 0")
        else
          changeset
        end

      nil ->
        changeset
    end
  end

  defp compact_number(n) when n >= 1_000_000 do
    rounded = Float.round(n / 1_000_000, 2)
    "#{rounded}M"
  end

  defp compact_number(n) when n >= 1_000 do
    rounded = Float.round(n / 1_000, 1)
    "#{rounded}K"
  end

  defp compact_number(n), do: "#{n}"

  defp format_cost(%Decimal{} = cost, "USD") do
    "$#{Decimal.round(cost, 4)}"
  end

  defp format_cost(%Decimal{} = cost, currency) do
    "#{Decimal.round(cost, 4)} #{currency}"
  end
end

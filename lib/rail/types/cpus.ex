defmodule Rail.Types.Cpus do
  @moduledoc """
  A CPU reservation, whole or in part: `1`, `0.5`, `1.25`. Stored as a float and
  read back as an integer when it is whole, so `2` reads as `2`, not `2.0`.
  """
  use Ecto.Type

  def type, do: :float

  def cast(cpus) when is_number(cpus), do: {:ok, whole(cpus)}

  def cast(cpus) when is_binary(cpus) do
    case Float.parse(String.trim(cpus)) do
      {parsed, ""} -> {:ok, whole(parsed)}
      _unparsed -> :error
    end
  end

  def cast(_other), do: :error

  def load(cpus) when is_number(cpus), do: {:ok, whole(cpus)}
  def load(_other), do: :error

  def dump(cpus) when is_number(cpus), do: {:ok, cpus / 1}
  def dump(_other), do: :error

  defp whole(cpus) when is_float(cpus) and cpus == trunc(cpus), do: trunc(cpus)
  defp whole(cpus), do: cpus
end

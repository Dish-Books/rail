defmodule Rail.Pipeline.Types.ViewedDiffFiles do
  @moduledoc """
  Custom Ecto type for `viewed_diff_files`.
  Stores a map of `%{path => digest}` while handling legacy list defaults `[]` or nil.
  """
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(map) when is_map(map), do: {:ok, map}
  def cast(list) when is_list(list), do: {:ok, Map.new(list, fn path -> {to_string(path), ""} end)}
  def cast(nil), do: {:ok, %{}}
  def cast(_other), do: :error

  @impl true
  def load(map) when is_map(map), do: {:ok, map}
  def load(list) when is_list(list), do: {:ok, Map.new(list, fn path -> {to_string(path), ""} end)}
  def load(nil), do: {:ok, %{}}
  def load(_other), do: :error

  @impl true
  def dump(map) when is_map(map), do: {:ok, map}
  def dump(list) when is_list(list), do: {:ok, Map.new(list, fn path -> {to_string(path), ""} end)}
  def dump(nil), do: {:ok, %{}}
  def dump(_other), do: :error
end

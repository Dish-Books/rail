defmodule Rail.Domain.Enums.Mergeability do
  @moduledoc """
  Mergeability status of a pull request branch according to GitHub.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :mergeable,
      :conflicting,
      :unknown
    ],
    labels: %{
      mergeable: "Mergeable",
      conflicting: "Conflicting",
      unknown: "Unknown"
    }

  @doc "Returns true if the branch has merge conflicts against base."
  def conflicting?(:conflicting), do: true
  def conflicting?(_other), do: false

  @doc "Returns true if the branch is cleanly mergeable."
  def mergeable?(:mergeable), do: true
  def mergeable?(_other), do: false

  @doc "Returns true if the mergeability state is unknown or pending computation."
  def unknown?(:unknown), do: true
  def unknown?(_other), do: false

  @doc """
  Parses the mergeable status string returned by GitHub CLI or API.
  Defaults to :unknown on any unrecognized or empty input.
  """
  def parse(raw) when is_binary(raw) do
    case raw |> String.trim() |> String.upcase() do
      "MERGEABLE" -> :mergeable
      "CONFLICTING" -> :conflicting
      _other -> :unknown
    end
  end

  def parse(_other), do: :unknown
end

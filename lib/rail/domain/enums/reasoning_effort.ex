defmodule Rail.Domain.Enums.ReasoningEffort do
  @moduledoc """
  Reasoning effort level configured for an agent model run.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :low,
      :medium,
      :high
    ],
    labels: %{
      low: "Low",
      medium: "Medium",
      high: "High"
    }

  @doc "Returns true if reasoning effort is low."
  def low?(:low), do: true
  def low?(_other), do: false

  @doc "Returns true if reasoning effort is medium."
  def medium?(:medium), do: true
  def medium?(_other), do: false

  @doc "Returns true if reasoning effort is high."
  def high?(:high), do: true
  def high?(_other), do: false
end

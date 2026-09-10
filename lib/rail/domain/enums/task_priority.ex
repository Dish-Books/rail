defmodule Rail.Domain.Enums.TaskPriority do
  @moduledoc """
  Priority levels for tasks and issues.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :urgent,
      :high,
      :medium,
      :low
    ],
    labels: %{
      urgent: "Urgent",
      high: "High",
      medium: "Medium",
      low: "Low"
    }
end

defmodule Rail.Domain.Enums.CheckSeverity do
  @moduledoc """
  Severity ranking for a QA finding or defect.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :blocker,
      :critical,
      :major,
      :minor,
      :cosmetic
    ],
    labels: %{
      blocker: "Blocker",
      critical: "Critical",
      major: "Major",
      minor: "Minor",
      cosmetic: "Cosmetic"
    }

  @doc "Returns true if the severity blocks shipping (blocker or critical)."
  def blocking?(severity) when is_atom(severity), do: severity in [:blocker, :critical]
  def blocking?(_other), do: false

  @doc "Returns true if the severity is blocker."
  def blocker?(:blocker), do: true
  def blocker?(_other), do: false

  @doc "Returns true if the severity is critical."
  def critical?(:critical), do: true
  def critical?(_other), do: false
end

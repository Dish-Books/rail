defmodule Rail.Domain.Enums.CliBackend do
  @moduledoc """
  Supported coding agent CLI backends.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :claude,
      :agy
    ],
    labels: %{
      claude: "Claude",
      agy: "Antigravity"
    }

  @doc "Returns true if the backend is Claude."
  def claude?(:claude), do: true
  def claude?(_other), do: false

  @doc "Returns true if the backend is Antigravity."
  def agy?(:agy), do: true
  def agy?(_other), do: false
end

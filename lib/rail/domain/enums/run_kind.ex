defmodule Rail.Domain.Enums.RunKind do
  @moduledoc """
  The kind of run dispatched for an agent role.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :stage,
      :chat,
      :improve
    ],
    labels: %{
      stage: "Stage",
      chat: "Chat",
      improve: "Improve"
    }

  @doc "Returns true if the run is executing a normal pipeline stage."
  def stage?(:stage), do: true
  def stage?(_other), do: false

  @doc "Returns true if the run is an interactive chat conversation turn."
  def chat?(:chat), do: true
  def chat?(_other), do: false

  @doc "Returns true if the run is an improve-instructions role run."
  def improve?(:improve), do: true
  def improve?(_other), do: false
end

defmodule Rail.Domain.Enums.RunStatus do
  @moduledoc """
  Status of an executing agent CLI process.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :starting,
      :running,
      :finished,
      :adopted_dead,
      :blocked_on_input
    ],
    labels: %{
      starting: "Starting",
      running: "Running",
      finished: "Finished",
      adopted_dead: "Adopted dead",
      blocked_on_input: "Blocked on input"
    }

  @doc "Returns true if the run has reached a terminal status."
  def terminal?(status) when is_atom(status), do: status in [:finished, :adopted_dead]
  def terminal?(_other), do: false

  @doc "Returns true if the run is currently in flight or starting."
  def live?(status) when is_atom(status), do: status in [:starting, :running]
  def live?(_other), do: false
end

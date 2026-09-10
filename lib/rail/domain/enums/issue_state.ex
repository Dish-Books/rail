defmodule Rail.Domain.Enums.IssueState do
  @moduledoc """
  Lifecycle state of an issue mirrored from Linear.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :triage,
      :backlog,
      :in_progress,
      :done,
      :canceled
    ],
    labels: %{
      triage: "Triage",
      backlog: "Backlog",
      in_progress: "In Progress",
      done: "Done",
      canceled: "Canceled"
    }

  @doc "Returns true if the issue is in a finished or terminal state."
  def finished?(state) when is_atom(state), do: state in [:done, :canceled]
  def finished?(_other), do: false

  @doc "Alias for finished?/1."
  def closed?(state), do: finished?(state)

  @doc "Returns true if the issue is actively being planned or worked."
  def active?(state) when is_atom(state), do: state in [:triage, :backlog, :in_progress]
  def active?(_other), do: false
end

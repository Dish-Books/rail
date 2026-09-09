defmodule Rail.Domain.Enums.TaskStageState do
  @moduledoc """
  The lifecycle state of a task at its current stage.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :idle,
      :queued,
      :running,
      :paused_question,
      :paused_chat,
      :awaiting_approval,
      :changes_requested,
      :failed,
      :canceled,
      :blocked_rework,
      :blocked
    ],
    labels: %{
      idle: "Idle",
      queued: "Queued",
      running: "Running",
      paused_question: "Paused (Question)",
      paused_chat: "Paused (Chat)",
      awaiting_approval: "Awaiting approval",
      changes_requested: "Changes requested",
      failed: "Failed",
      canceled: "Canceled",
      blocked_rework: "Blocked rework",
      blocked: "Blocked"
    }

  @doc "Returns true if the stage state is paused awaiting human input."
  def paused?(state) when is_atom(state), do: state in [:paused_question, :paused_chat, :blocked]
  def paused?(_other), do: false

  @doc "Returns true if the stage state has terminated without completing."
  def terminal?(state) when is_atom(state), do: state in [:failed, :canceled]
  def terminal?(_other), do: false

  @doc "Returns true if the stage state is actively running."
  def running?(:running), do: true
  def running?(_other), do: false

  @doc "Returns true if the stage state is queued for an agent slot."
  def queued?(:queued), do: true
  def queued?(_other), do: false

  @doc "Returns true if the stage state is waiting on human approval."
  def awaiting_approval?(:awaiting_approval), do: true
  def awaiting_approval?(_other), do: false

  @doc "Returns true if the stage state is actively being processed or chatted with."
  def active?(state) when is_atom(state), do: state in [:running, :paused_chat]
  def active?(_other), do: false
end

defmodule Rail.Domain.Enums.QuestionStatus do
  @moduledoc """
  Status of an agent question blocking a task.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :pending,
      :answered,
      :dismissed
    ],
    labels: %{
      pending: "Pending",
      answered: "Answered",
      dismissed: "Dismissed"
    }

  @doc "Returns true if the question is pending an answer."
  def pending?(:pending), do: true
  def pending?(_other), do: false

  @doc "Returns true if the question has been resolved (answered or dismissed)."
  def resolved?(status) when is_atom(status), do: status in [:answered, :dismissed]
  def resolved?(_other), do: false
end

defmodule Rail.Pipeline.Schemas.Question do
  @moduledoc """
  Schema for an agent question that pauses a task pending human answer or dismissal.

  Rail answers one itself when a person already answered one like it, with
  `answered_by_rail` set, and suggests a likely past answer where it is less sure.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @statuses [:pending, :unanswered, :answered, :dismissed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "qst"}
  schema "questions" do
    belongs_to :task, Task
    belongs_to :run, Run

    field :prompt, :string
    field :options, {:array, :string}, default: []
    field :context_summary, :string
    field :answer, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :answered_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :answered_by_rail, :boolean, default: false

    belongs_to :answered_by, User
    belongs_to :suggested_learning, Learning

    timestamps()
  end

  @cast_fields [
    :task_id,
    :run_id,
    :prompt,
    :options,
    :context_summary,
    :answer,
    :status,
    :answered_at,
    :delivered_at,
    :answered_by_id,
    :answered_by_rail,
    :suggested_learning_id
  ]

  @required_fields [
    :task_id,
    :run_id,
    :prompt,
    :status
  ]

  @doc """
  Builds a changeset for an agent question.
  """
  def changeset(question, attrs, task_id \\ nil) do
    question
    |> cast(attrs, @cast_fields)
    |> maybe_put_task_id(task_id)
    |> clear_answer_on_dismiss()
    |> clear_rail_on_person()
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:run_id)
  end

  def statuses, do: @statuses

  def pending?(:pending), do: true
  def pending?(_other), do: false

  def resolved?(status) when is_atom(status), do: status in [:answered, :dismissed]
  def resolved?(_other), do: false

  # A dismissed question never carries a stale answer back to the agent or into Answer instead.
  defp clear_answer_on_dismiss(changeset) do
    case get_change(changeset, :status) do
      :dismissed -> change(changeset, answer: nil, answered_at: nil)
      _other -> changeset
    end
  end

  # Once a person answers, the answer is theirs and no longer Rail's.
  defp clear_rail_on_person(changeset) do
    case get_change(changeset, :answered_by_id) do
      user_id when is_binary(user_id) -> put_change(changeset, :answered_by_rail, false)
      nil -> changeset
    end
  end

  defp maybe_put_task_id(changeset, nil), do: changeset
  defp maybe_put_task_id(changeset, task_id), do: put_change(changeset, :task_id, task_id)
end

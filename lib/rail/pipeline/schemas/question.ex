defmodule Rail.Pipeline.Schemas.Question do
  @moduledoc """
  Schema for an agent question that pauses a task pending human answer or dismissal.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  @statuses [:pending, :unanswered, :answered, :dismissed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "qst"}
  schema "questions" do
    belongs_to :task, Task
    belongs_to :role, Role

    field :prompt, :string
    field :options, {:array, :string}, default: []
    field :context_summary, :string
    field :answer, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :answered_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :task_id,
    :role_id,
    :prompt,
    :options,
    :context_summary,
    :answer,
    :status,
    :answered_at,
    :delivered_at
  ]

  @required_fields [
    :task_id,
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
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:role_id)
  end

  def statuses, do: @statuses

  def pending?(:pending), do: true
  def pending?(_other), do: false

  def resolved?(status) when is_atom(status), do: status in [:answered, :dismissed]
  def resolved?(_other), do: false

  defp maybe_put_task_id(changeset, nil), do: changeset
  defp maybe_put_task_id(changeset, task_id), do: put_change(changeset, :task_id, task_id)
end

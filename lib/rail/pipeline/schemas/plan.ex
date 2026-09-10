defmodule Rail.Pipeline.Schemas.Plan do
  @moduledoc """
  Schema for an architectural or implementation plan associated with a task.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @primary_key {:id, UXID, autogenerate: true, prefix: "pln"}
  schema "plans" do
    belongs_to :task, Task

    field :content, :string
    field :captured_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :task_id,
    :content,
    :captured_at
  ]

  @required_fields [
    :task_id,
    :content,
    :captured_at
  ]

  @doc """
  Builds a changeset for a plan.
  """
  def changeset(plan, attrs, task_id \\ nil) do
    plan
    |> cast(attrs, @cast_fields)
    |> maybe_put_task_id(task_id)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
  end

  defp maybe_put_task_id(changeset, nil), do: changeset
  defp maybe_put_task_id(changeset, task_id), do: put_change(changeset, :task_id, task_id)
end

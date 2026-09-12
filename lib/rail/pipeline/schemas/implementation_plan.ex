defmodule Rail.Pipeline.Schemas.ImplementationPlan do
  @moduledoc """
  The plan the architect wrote for a task.

  One per task: a second architect pass replaces what the first one said rather
  than leaving two plans for a reader to choose between.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @primary_key {:id, UXID, autogenerate: true, prefix: "pln"}
  schema "implementation_plans" do
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
  Builds a changeset for an implementation plan.
  """
  def changeset(implementation_plan, attrs, task_id \\ nil) do
    implementation_plan
    |> cast(attrs, @cast_fields)
    |> maybe_put_task_id(task_id)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id)
  end

  defp maybe_put_task_id(changeset, nil), do: changeset
  defp maybe_put_task_id(changeset, task_id), do: put_change(changeset, :task_id, task_id)
end

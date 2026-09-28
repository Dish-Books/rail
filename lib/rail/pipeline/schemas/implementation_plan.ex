defmodule Rail.Pipeline.Schemas.ImplementationPlan do
  @moduledoc """
  The plan the architect wrote for a task, once a human approved it.

  One per task: a second architect pass replaces what the first one said rather
  than leaving two plans for a reader to choose between. The plan lives in scratch
  while it is being written and argued over; a row here means it was approved.
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
  def changeset(implementation_plan, attrs) do
    implementation_plan
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id)
  end

  @doc """
  The defaults the plan took for a human to veto: the bullets under its
  `Assumptions` heading, which the architect writes flat and one line each.
  """
  def assumptions(%__MODULE__{content: content}) do
    content
    |> String.split(~r/\R/)
    |> Enum.drop_while(&(not Regex.match?(~r/\A\#{2,4} Assumptions\s*\z/, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A[-*] (.+)\z/, String.trim_trailing(line)) do
        [_line, assumption] -> [String.trim(assumption)]
        nil -> []
      end
    end)
  end
end

defmodule Rail.Pipeline.Schemas.Round do
  @moduledoc """
  One pass of a task from a plan through the engineer to its review, numbered from 1. Round 1's plan is the task's
  initial plan, and each later round's is the one the review before it wrote.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "rnd"}
  schema "rounds" do
    field :number, :integer
    field :plan, :string
    field :plan_version, :integer, default: 0
    field :plan_saved_at, :utc_datetime_usec
    # Whether the plan asks for a new demo once the round is reviewed.
    field :record_demo, :boolean, default: false
    field :approved_at, :utc_datetime_usec
    # The branch's HEAD when the round started, and the one its review read.
    field :base_head, :string
    field :head, :string
    field :reviewed_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :task, Task
    belongs_to :approved_by, User

    timestamps()
  end

  @doc """
  Builds a changeset for `task`'s round `number`, which only Rail sets.
  """
  def changeset(%Task{id: task_id}, number) when is_integer(number) and number > 0 do
    %__MODULE__{task_id: task_id, number: number}
    |> change()
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :number])
  end

  @doc """
  Takes the round's next plan from `attrs`, with whether it asks for a demo, as its next version.
  """
  def plan_changeset(%__MODULE__{} = round, attrs) do
    round
    |> cast(attrs, [:plan, :record_demo])
    |> update_change(:plan, &String.trim/1)
    |> validate_required([:plan])
    |> change(plan_version: round.plan_version + 1, plan_saved_at: DateTime.utc_now())
  end

  @doc """
  Where the round stands: `:planning` with no plan saved, `:waiting` on approval, `:working` once approved,
  `:reviewed` once its review is saved, or `:finished`.
  """
  def state(%__MODULE__{finished_at: %DateTime{}}), do: :finished
  def state(%__MODULE__{reviewed_at: %DateTime{}}), do: :reviewed
  def state(%__MODULE__{approved_at: %DateTime{}}), do: :working
  def state(%__MODULE__{plan: plan}) when is_binary(plan), do: :waiting
  def state(%__MODULE__{}), do: :planning
end

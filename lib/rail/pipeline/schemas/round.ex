defmodule Rail.Pipeline.Schemas.Round do
  @moduledoc """
  One pass of a task from a plan through the engineer to its review, numbered from 1. Round 1's plan is the task's
  initial plan, with the ticket and the design option it is written for, and each later round's is the one the
  review before it wrote.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.ImplementationPlan
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
    # When its plan was sent to a tech lead, which saving the plan again undoes.
    field :ready_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    # The branch's HEAD when the round started, and the one its review read.
    field :base_head, :string
    field :head, :string
    field :reviewed_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    embeds_one :ticket, Ticket, primary_key: false, on_replace: :update do
      field :title, :string
      field :description, :string
      field :priority, Ecto.Enum, values: Issue.priorities()
      field :estimate, :integer
    end

    # The design option the plan is written for, kept by name since the pick deletes the others.
    embeds_one :design, Design, primary_key: false, on_replace: :delete do
      field :key, :string
      field :title, :string
    end

    belongs_to :task, Task
    belongs_to :ready_by, User
    belongs_to :approved_by, User

    timestamps()
  end

  @doc """
  Builds a changeset for `task`'s round after `previous`, carrying its ticket and design forward, or its first
  round when `previous` is nil.
  """
  def changeset(%Task{id: task_id}, nil), do: build(%__MODULE__{task_id: task_id, number: 1})

  def changeset(%Task{id: task_id}, %__MODULE__{} = previous) do
    build(%__MODULE__{task_id: task_id, number: previous.number + 1, ticket: previous.ticket, design: previous.design})
  end

  @doc """
  Builds a changeset for the first round of a split's `child` task: its ticket and its part of the parent's plan,
  approved with the parent's.
  """
  def child_changeset(%Task{} = task, child) do
    now = DateTime.utc_now()

    task
    |> changeset(nil)
    |> change(plan: child.plan, plan_version: 1, plan_saved_at: now, approved_at: now)
    |> put_embed(:ticket, %__MODULE__.Ticket{title: child.title, description: child.ticket, estimate: child.estimate})
  end

  @doc """
  Takes the round's next save from `attrs` as its next version: the `plan`, the `ticket`, the `design` option the
  plan is written for and whether it asks for a demo. A ticket field left out keeps what the last save set. Round 1
  needs its ticket and takes its plan when there is one, in the sections Rail lays a plan out by; a later round
  needs its plan.
  """
  def plan_changeset(%__MODULE__{number: number} = round, attrs) do
    round
    |> cast(attrs, [:plan, :record_demo])
    |> update_change(:plan, &trim/1)
    |> validate_plan_given()
    |> cast_embed(:ticket, with: &ticket_changeset/2, required: number == 1)
    |> cast_embed(:design, with: &cast(&1, &2, [:key, :title]))
    |> validate_plan(number)
    |> change(plan_version: round.plan_version + 1, plan_saved_at: DateTime.utc_now(), ready_at: nil, ready_by_id: nil)
    |> unique_constraint([:task_id, :number])
  end

  @doc """
  Builds a changeset marking the round's plan sent to a tech lead by `user_id`, which is nil when Rail sent it.
  A plan already sent keeps who sent it and when.
  """
  def ready_changeset(%__MODULE__{ready_at: %DateTime{}} = round, _user_id), do: change(round)

  def ready_changeset(%__MODULE__{} = round, user_id),
    do: change(round, ready_at: DateTime.utc_now(), ready_by_id: user_id)

  @doc """
  Builds a changeset marking the round approved by `user_id`, which is nil when Rail approved it.
  """
  def approve_changeset(%__MODULE__{} = round, user_id) do
    change(round, approved_at: DateTime.utc_now(), approved_by_id: user_id)
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

  defp build(%__MODULE__{} = round) do
    round
    |> change()
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :number])
  end

  defp ticket_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:title, :description, :priority, :estimate])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_required([:title, :description])
    |> validate_format(:title, ~r/\A[^\n]*\z/, message: "must be one line")
    |> validate_number(:estimate, greater_than_or_equal_to: 0, message: "must be zero or more")
  end

  # A blank casts to nil, which would otherwise clear a saved plan rather than be refused.
  defp validate_plan_given(changeset) do
    case fetch_change(changeset, :plan) do
      {:ok, nil} -> add_error(changeset, :plan, "can't be blank")
      _given_or_left_out -> changeset
    end
  end

  defp trim(nil), do: nil
  defp trim(text), do: String.trim(text)

  defp validate_plan(changeset, 1) do
    changeset
    |> validate_format(:plan, ~r/\A## Implementation plan\s*(\n|\z)/,
      message: "must open with the `## Implementation plan` heading"
    )
    |> ImplementationPlan.validate_structure(:plan)
  end

  defp validate_plan(changeset, _later), do: validate_required(changeset, [:plan])
end

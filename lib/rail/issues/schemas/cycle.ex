defmodule Rail.Issues.Schemas.Cycle do
  @moduledoc """
  A Rail-tracked project's cycle, both of its dates included. Postgres numbers it as it is inserted, and keeps two cycles
  of one project from sharing a day.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.CycleDay
  alias Rail.Projects.Schemas.Project

  @default_estimate 1

  @primary_key {:id, UXID, autogenerate: true, prefix: "cyc"}
  schema "cycles" do
    field :number, :integer, read_after_writes: true
    field :starts_on, :date
    field :ends_on, :date

    belongs_to :project, Project
    has_many :days, CycleDay, preload_order: [asc: :day]

    timestamps()
  end

  @doc "A new cycle's dates. Its project is set on the struct, by whoever schedules it."
  def changeset(cycle, attrs) do
    cycle
    |> cast(attrs, [:starts_on, :ends_on])
    |> validate_dates()
  end

  @doc """
  An edit of the cycle's dates on `today`. An ended cycle keeps its dates, a running one keeps its start and ends today
  or later, and an upcoming one starts today or later.
  """
  def dates_changeset(%__MODULE__{} = cycle, attrs, %Date{} = today) do
    changeset = cast(cycle, attrs, [:starts_on, :ends_on])
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)

    refused =
      case calculate_status(cycle, today) do
        :ended ->
          [ends_on: "This cycle has ended, so its dates cannot change."]

        :running ->
          [
            starts_on: starts_on != cycle.starts_on && "A running cycle keeps its start.",
            ends_on: before?(ends_on, today) && "A running cycle cannot end before today."
          ]

        :upcoming ->
          [starts_on: before?(starts_on, today) && "An upcoming cycle cannot start before today."]
      end

    changeset =
      for {field, message} <- refused, is_binary(message), reduce: changeset, do: (acc -> add_error(acc, field, message))

    validate_dates(changeset)
  end

  @doc "Running while `today` falls within its dates, else upcoming or ended."
  def calculate_status(%__MODULE__{starts_on: starts_on, ends_on: ends_on}, %Date{} = today) do
    cond do
      Date.before?(today, starts_on) -> :upcoming
      Date.after?(today, ends_on) -> :ended
      true -> :running
    end
  end

  @doc "The points an unestimated Rail-tracked issue counts."
  def default_estimate, do: @default_estimate

  defp validate_dates(changeset) do
    changeset = validate_required(changeset, [:starts_on, :ends_on], message: "Pick both dates.")

    changeset =
      if before?(get_field(changeset, :ends_on), get_field(changeset, :starts_on)),
        do: add_error(changeset, :ends_on, "The end must be on or after the start."),
        else: changeset

    changeset
    |> exclusion_constraint(:starts_on, name: :cycles_no_overlap, message: "These dates overlap an earlier cycle.")
    |> check_constraint(:ends_on, name: :cycles_ends_after_start, message: "The end must be on or after the start.")
  end

  defp before?(%Date{} = date, %Date{} = other), do: Date.before?(date, other)
  defp before?(_missing, _other), do: false
end

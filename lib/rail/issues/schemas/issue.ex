defmodule Rail.Issues.Schemas.Issue do
  @moduledoc false
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @priorities [:urgent, :high, :medium, :low]
  @states [:backlog, :triage, :todo, :in_progress, :in_review, :done, :canceled]

  @derive {LiveSync.Watch, subscription_key: :project_id, table: "issues"}
  @primary_key {:id, UXID, autogenerate: true, prefix: "iss"}
  schema "issues" do
    belongs_to :project, Project
    field :external_id, :string
    field :identifier, :string
    field :title, :string
    field :description, :string
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :state, Ecto.Enum, values: @states
    field :state_name, :string
    field :branch_name, :string
    field :url, :string
    field :linear_created_at, :utc_datetime_usec
    field :linear_updated_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :external_id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_name,
    :branch_name,
    :url,
    :linear_created_at,
    :linear_updated_at
  ]

  @required_fields [
    :project_id,
    :external_id,
    :identifier,
    :title,
    :state
  ]

  def changeset(issue, attrs, project_id \\ nil) do
    issue
    |> cast(attrs, @cast_fields)
    |> maybe_put_project_id(project_id)
    |> validate_required(@required_fields)
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:project_id)
  end

  def priorities, do: @priorities
  def states, do: @states

  def priority_label(:urgent), do: "Urgent"
  def priority_label(:high), do: "High"
  def priority_label(:medium), do: "Medium"
  def priority_label(:low), do: "Low"
  def priority_label(_other), do: nil

  def state_label(:backlog), do: "Backlog"
  def state_label(:triage), do: "Triage"
  def state_label(:todo), do: "Todo"
  def state_label(:in_progress), do: "In Progress"
  def state_label(:in_review), do: "In Review"
  def state_label(:done), do: "Done"
  def state_label(:canceled), do: "Canceled"
  def state_label(_other), do: nil

  def finished_state?(state) when is_atom(state), do: state in [:done, :canceled]
  def finished_state?(_other), do: false

  def finished?(state), do: finished_state?(state)
  def closed?(state), do: finished_state?(state)

  def active?(state) when is_atom(state), do: state in [:triage, :backlog, :todo, :in_progress, :in_review]
  def active?(_other), do: false

  def cast_priority(priority) when is_atom(priority) do
    if priority in @priorities, do: {:ok, priority}, else: :error
  end

  def cast_priority(priority) when is_binary(priority) do
    found = Enum.find(@priorities, fn p -> Atom.to_string(p) == priority end)
    if found, do: {:ok, found}, else: :error
  end

  def cast_priority(_other), do: :error

  def cast_state(state) when is_atom(state) do
    if state in @states, do: {:ok, state}, else: :error
  end

  def cast_state(state) when is_binary(state) do
    normalized =
      state
      |> Macro.underscore()
      |> String.downcase()

    found =
      Enum.find(@states, fn s ->
        Atom.to_string(s) == state or Atom.to_string(s) == normalized
      end)

    if found, do: {:ok, found}, else: :error
  end

  def cast_state(_other), do: :error

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end

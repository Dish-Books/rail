defmodule Rail.Issues.Schemas.Issue do
  @moduledoc false
  use Rail.Schema

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User

  @priorities [:urgent, :high, :medium, :low]
  @states [:backlog, :triage, :todo, :in_progress, :in_review, :done, :canceled, :duplicate]
  @finished_states [:done, :canceled, :duplicate]

  @primary_key {:id, UXID, autogenerate: true, prefix: "iss"}
  schema "issues" do
    field :external_id, :string
    field :identifier, :string
    field :title, :string
    field :description, :string
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :estimate, :integer
    field :state, Ecto.Enum, values: @states
    field :state_name, :string
    field :branch_name, :string
    field :url, :string
    field :completed_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :owner_user, User

    # The live task. Cleaned-up tasks stay in the table as history.
    has_one :task, Task, where: [cleaned_up_at: nil]
    has_many :comments, Comment

    timestamps()
  end

  @cast_fields [
    :branch_name,
    :completed_at,
    :description,
    :estimate,
    :external_id,
    :identifier,
    :owner_user_id,
    :priority,
    :project_id,
    :state_name,
    :state,
    :title,
    :url
  ]

  @required_fields [
    :project_id,
    :external_id,
    :identifier,
    :title,
    :state
  ]

  def changeset(issue, attrs) do
    issue
    |> linear_changeset(attrs)
    |> sync_to_linear()
  end

  @doc """
  A changeset for what Linear itself reports, such as a webhook. It is the same
  as `changeset/2` except that nothing is queued to push back to Linear, since
  Linear is where the change came from.
  """
  def linear_changeset(issue, attrs) do
    issue
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:owner_user_id)
  end

  def priorities, do: @priorities
  def states, do: @states
  def finished_states, do: @finished_states

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
  def state_label(:duplicate), do: "Duplicate"
  def state_label(_other), do: nil

  def finished_state?(state) when is_atom(state), do: state in @finished_states
  def finished_state?(_other), do: false

  def finished?(state), do: finished_state?(state)
  def closed?(state), do: finished_state?(state)

  def active?(state) when is_atom(state), do: state in [:triage, :backlog, :todo, :in_progress, :in_review]
  def active?(_other), do: false

  # Every write goes up to Linear, so no caller can forget to say so. This runs
  # inside the write's own transaction, which is what makes the job and the row
  # land together or not at all. An insert has nothing to sync back: the ticket
  # is opened in Linear first and the row is what came back from it.
  defp sync_to_linear(%Ecto.Changeset{data: %__MODULE__{id: id}, changes: changes} = changeset)
       when is_binary(id) and changes != %{} do
    prepare_changes(changeset, fn prepared ->
      %{issue_id: id, fields: Map.keys(prepared.changes)}
      |> SyncIssue.new()
      |> Oban.insert!()

      prepared
    end)
  end

  defp sync_to_linear(%Ecto.Changeset{} = changeset), do: changeset
end

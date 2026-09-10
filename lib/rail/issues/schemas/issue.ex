defmodule Rail.Issues.Schemas.Issue do
  @moduledoc false
  use Rail.Schema

  alias Rail.Domain.Enums.IssueState
  alias Rail.Domain.Enums.TaskPriority
  alias Rail.Projects.Schemas.Project

  @derive {LiveSync.Watch, subscription_key: :project_id, table: "issues"}
  @primary_key {:id, UXID, autogenerate: true, prefix: "iss"}
  schema "issues" do
    belongs_to :project, Project
    field :external_id, :string
    field :identifier, :string
    field :title, :string
    field :description, :string
    field :priority, TaskPriority, default: :medium
    field :state, IssueState
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

  def factory do
    id = System.unique_integer([:positive])

    %__MODULE__{
      external_id: "lin_iss_#{id}",
      identifier: "ENG-#{id}",
      title: "Issue #{id}",
      description: "Description for issue #{id}",
      priority: :medium,
      state: :triage,
      state_name: "Triage",
      branch_name: "eng-#{id}-branch",
      url: "https://linear.app/issue/ENG-#{id}",
      linear_created_at: DateTime.utc_now(),
      linear_updated_at: DateTime.utc_now()
    }
  end

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end

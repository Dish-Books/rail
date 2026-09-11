defmodule Rail.Projects.Schemas.Project do
  @moduledoc false
  use Rail.Schema

  alias Rail.Projects.Schemas.LinearWorkspace

  @primary_key {:id, UXID, autogenerate: true, prefix: "prj"}
  schema "projects" do
    field :name, :string
    field :github_repo, :string
    field :github_installation_id, :integer
    field :default_branch, :string
    field :linear_team_id, :string
    field :linear_team_key, :string
    field :linear_state_ids, :map, default: %{}
    field :clone_path, :string
    field :active, :boolean, default: true

    belongs_to :linear_workspace, LinearWorkspace

    timestamps()
  end

  @fields [
    :name,
    :github_repo,
    :github_installation_id,
    :default_branch,
    :linear_workspace_id,
    :linear_team_id,
    :linear_team_key,
    :linear_state_ids,
    :clone_path,
    :active
  ]

  @required_fields [
    :name,
    :github_repo,
    :github_installation_id,
    :default_branch,
    :linear_team_id,
    :linear_team_key,
    :clone_path
  ]

  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:github_repo)
    |> foreign_key_constraint(:linear_workspace_id)
  end
end

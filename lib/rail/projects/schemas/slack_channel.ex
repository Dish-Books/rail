defmodule Rail.Projects.Schemas.SlackChannel do
  @moduledoc """
  A Slack channel a project triages. Bot posts only trigger triage where
  `triage_bot_messages` is on, such as a channel an error tracker reports in.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackWorkspace

  @primary_key {:id, UXID, autogenerate: true, prefix: "sch"}
  schema "slack_channels" do
    field :external_id, :string
    field :name, :string
    field :triage_bot_messages, :boolean, default: false

    belongs_to :project, Project
    belongs_to :slack_workspace, SlackWorkspace

    timestamps()
  end

  def changeset(%Project{id: project_id}, %SlackWorkspace{id: workspace_id}, attrs) do
    %__MODULE__{project_id: project_id, slack_workspace_id: workspace_id}
    |> cast(attrs, [:external_id, :name, :triage_bot_messages])
    |> validate_required([:external_id, :name])
    |> unique_constraint(:external_id, message: "is connected to another project")
  end
end

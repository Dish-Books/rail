defmodule Rail.Projects.Schemas.SlackChannel do
  @moduledoc """
  A Slack channel a project triages. Bot posts only trigger triage where `bot_triage_enabled` is on,
  and an `external` channel is shared with people outside the team, so Rail never posts an issue link there.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackWorkspace

  @primary_key {:id, UXID, autogenerate: true, prefix: "sch"}
  schema "slack_channels" do
    field :external_id, :string
    field :name, :string
    field :bot_triage_enabled, :boolean, default: false
    field :external, :boolean, default: false

    belongs_to :project, Project
    belongs_to :slack_workspace, SlackWorkspace

    timestamps()
  end

  @doc """
  A channel as a project's channels form sets it, through `Project.slack_channels_changeset/2`.
  The form offers only what it just listed from Slack, so the id, name and workspace come from there.
  """
  def changeset(%__MODULE__{} = channel, attrs) do
    channel
    |> cast(attrs, [:external_id, :name, :slack_workspace_id, :bot_triage_enabled, :external])
    |> validate_required([:external_id, :name, :slack_workspace_id])
    |> foreign_key_constraint(:slack_workspace_id)
    |> unique_constraint(:external_id, message: "is connected to another project")
  end
end

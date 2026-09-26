defmodule Rail.Projects.Schemas.SlackWorkspace do
  @moduledoc """
  A Slack workspace Rail's app is installed in: the bot token that reads it and
  the app-level token its Socket Mode connection opens with.
  """
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @primary_key {:id, UXID, autogenerate: true, prefix: "sw"}
  schema "slack_workspaces" do
    field :name, :string
    field :external_id, :string
    field :token, EncryptedBinary, redact: true
    field :app_token, EncryptedBinary, redact: true
    field :bot_id, :string
    field :bot_user_id, :string

    has_many :channels, Rail.Projects.Schemas.SlackChannel

    timestamps()
  end

  # The form never shows a stored secret, so leaving one blank keeps it.
  def changeset(slack_workspace, attrs) do
    attrs = Map.reject(attrs, fn {key, value} -> to_string(key) in ["token", "app_token"] and value in ["", nil] end)

    slack_workspace
    |> cast(attrs, [:name, :token, :app_token])
    |> validate_required([:name, :token])
    |> unique_constraint(:external_id)
  end

  @doc """
  Puts who the bot token belongs to, as Slack's `auth.test` said.
  """
  def identity_changeset(changeset, %{"team_id" => team_id} = identity) do
    changeset
    |> put_change(:external_id, team_id)
    |> put_change(:bot_id, identity["bot_id"])
    |> put_change(:bot_user_id, identity["user_id"])
  end
end

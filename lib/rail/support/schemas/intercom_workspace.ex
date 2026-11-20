defmodule Rail.Support.Schemas.IntercomWorkspace do
  @moduledoc """
  An Intercom app Rail reads conversations through, and the project they belong to.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Types.EncryptedBinary

  @primary_key {:id, UXID, autogenerate: true, prefix: "iw"}
  schema "intercom_workspaces" do
    field :name, :string
    # Intercom's `app.id_code`, which webhooks name the workspace by.
    field :external_id, :string
    field :access_token, EncryptedBinary, redact: true
    field :client_id, :string
    field :client_secret, EncryptedBinary, redact: true

    belongs_to :project, Project

    timestamps()
  end

  def create_changeset(%Project{id: project_id}, attrs), do: changeset(%__MODULE__{project_id: project_id}, attrs)

  # The form never shows a stored secret, so leaving one blank keeps it.
  def changeset(workspace, attrs) do
    attrs =
      Map.reject(attrs, fn {key, value} -> to_string(key) in ["access_token", "client_secret"] and value in ["", nil] end)

    workspace
    |> cast(attrs, [:name, :access_token, :client_id, :client_secret])
    |> validate_required([:name, :project_id, :access_token, :client_id, :client_secret])
    |> unique_constraint(:external_id)
  end

  @doc """
  Puts the app the token belongs to, as Intercom's `/me` said.
  """
  def identity_changeset(changeset, %{"app" => %{"id_code" => app_id}}) when is_binary(app_id),
    do: put_change(changeset, :external_id, app_id)

  def identity_changeset(changeset, _unexpected),
    do: add_error(changeset, :access_token, "Intercom did not say which app this token belongs to")

  def inbox_url(%__MODULE__{external_id: app_id}, conversation_external_id),
    do: "https://app.intercom.com/a/inbox/#{app_id}/inbox/conversation/#{conversation_external_id}"
end

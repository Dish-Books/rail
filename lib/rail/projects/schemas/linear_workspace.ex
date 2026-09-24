defmodule Rail.Projects.Schemas.LinearWorkspace do
  @moduledoc false
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @primary_key {:id, UXID, autogenerate: true, prefix: "lw"}
  schema "linear_workspaces" do
    field :name, :string
    field :external_id, :string
    field :token, EncryptedBinary, redact: true
    field :webhook_secret, EncryptedBinary, redact: true

    has_many :projects, Rail.Projects.Schemas.Project

    timestamps()
  end

  # The form never shows a stored secret, so leaving one blank keeps it.
  def changeset(linear_workspace, attrs) do
    attrs = Map.reject(attrs, fn {key, value} -> to_string(key) in ["token", "webhook_secret"] and value in ["", nil] end)

    linear_workspace
    |> cast(attrs, [:name, :external_id, :token, :webhook_secret])
    |> validate_required([:name, :external_id, :token, :webhook_secret])
    |> unique_constraint(:external_id)
  end
end

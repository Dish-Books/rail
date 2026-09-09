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

  def changeset(linear_workspace, attrs) do
    linear_workspace
    |> cast(attrs, [:name, :external_id, :token, :webhook_secret])
    |> validate_required([:name, :external_id, :token, :webhook_secret])
    |> unique_constraint(:external_id)
  end

  def factory do
    id = System.unique_integer([:positive])

    %__MODULE__{
      name: "Workspace #{id}",
      external_id: "lin_ws_#{id}",
      token: "lin_api_token_#{id}",
      webhook_secret: "whsec_#{id}"
    }
  end
end

defmodule Rail.Backends.Schemas.Backend do
  @moduledoc """
  Schema for a CLI backend the user has configured: where its executable lives
  and which models may be selected for it.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.BackendModel

  @names [:claude, :agy, :codex]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bkd"}
  schema "backends" do
    field :name, Ecto.Enum, values: @names
    field :executable_path, :string
    embeds_many :models, BackendModel, on_replace: :delete

    timestamps()
  end

  @cast_fields [:name, :executable_path]
  @required_fields [:name, :executable_path]

  @doc "Returns the backends that can be configured."
  def names, do: @names

  @doc "Builds a changeset for a backend."
  def changeset(backend, attrs) do
    backend
    |> cast(attrs, @cast_fields)
    |> update_change(:executable_path, &String.trim/1)
    |> validate_required(@required_fields)
    |> cast_embed(:models)
    |> unique_constraint(:name)
  end
end

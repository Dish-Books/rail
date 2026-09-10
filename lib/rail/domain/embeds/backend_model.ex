defmodule Rail.Domain.Embeds.BackendModel do
  @moduledoc """
  A model the user has made available on a CLI backend.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :id, :string
    field :display_name, :string
  end

  @fields [:id, :display_name]
  @required_fields [:id]

  @doc "Builds a changeset for a backend model."
  def changeset(model, attrs) do
    model
    |> cast(attrs, @fields)
    |> update_change(:id, &String.trim/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required(@required_fields)
    |> default_display_name()
  end

  defp default_display_name(changeset) do
    case get_field(changeset, :display_name) do
      name when is_binary(name) and name != "" -> changeset
      _blank -> put_change(changeset, :display_name, get_field(changeset, :id))
    end
  end
end

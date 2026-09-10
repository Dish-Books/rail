defmodule Rail.Backends.Schemas.CliAccount do
  @moduledoc """
  Schema for tracking CLI backend accounts, authentication status, and usage quotas.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.CliAccountGroup

  @statuses ["not_configured", "signed_out", "unavailable", "ready"]
  @backends [:claude, :agy, :codex]

  @primary_key {:id, UXID, autogenerate: true, prefix: "cli"}
  schema "cli_accounts" do
    field :node, :string, default: "local"
    field :backend, Ecto.Enum, values: @backends
    field :status, :string
    field :account_label, :string
    field :account_detail, :string
    embeds_many :groups, CliAccountGroup, on_replace: :delete
    field :fetched_at, :utc_datetime_usec
    field :unavailable_reason, :string

    timestamps()
  end

  @cast_fields [
    :node,
    :backend,
    :status,
    :account_label,
    :account_detail,
    :fetched_at,
    :unavailable_reason
  ]

  @required_fields [:node, :backend, :status]

  @doc "Builds a changeset for a CLI account."
  def changeset(cli_account, attrs) do
    cli_account
    |> cast(attrs, @cast_fields)
    |> put_default_node()
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> cast_embed(:groups)
    |> unique_constraint([:node, :backend], name: :cli_accounts_node_backend_index)
  end

  @doc "Returns the supported backends list."
  def backends, do: @backends

  @doc "Returns the default node string identifier."
  def default_node(node \\ Node.self()) do
    case node do
      :nonode@nohost -> "local"
      other -> to_string(other)
    end
  end

  defp put_default_node(changeset) do
    case get_field(changeset, :node) do
      node when is_binary(node) and node != "" -> changeset
      _other -> put_change(changeset, :node, default_node())
    end
  end
end

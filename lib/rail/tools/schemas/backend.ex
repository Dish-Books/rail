defmodule Rail.Tools.Schemas.Backend do
  @moduledoc """
  Schema for a CLI backend: where its executable lives, which models may be
  selected for it, and what the last usage probe found out about the account
  signed in to it.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.BackendModel

  @names [:claude, :agy, :codex]
  @statuses [:not_configured, :signed_out, :unavailable, :ready]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bkd"}
  schema "backends" do
    field :name, Ecto.Enum, values: @names
    field :executable_path, :string, default: ""
    embeds_many :models, BackendModel, on_replace: :delete

    field :status, Ecto.Enum, values: @statuses, default: :not_configured
    field :account_label, :string
    field :account_detail, :string
    field :fetched_at, :utc_datetime_usec
    field :unavailable_reason, :string

    # A group of quota limits the CLI reported, with the windows it measured
    # them over carried in `details`.
    embeds_many :usage, Usage, primary_key: false, on_replace: :delete do
      @derive Jason.Encoder
      field :name, :string
      field :count, :integer, default: 0
      field :details, :map, default: %{}
    end

    timestamps()
  end

  @config_fields [:name, :executable_path]
  @usage_fields [:name, :status, :account_label, :account_detail, :fetched_at, :unavailable_reason]

  @doc "Returns the backends that can be configured."
  def names, do: @names

  @doc "Returns the statuses a usage probe can report."
  def statuses, do: @statuses

  @doc """
  Builds a changeset for the configuration the user owns: the executable path
  and the models selectable on it.
  """
  def changeset(backend, attrs) do
    backend
    |> cast(attrs, @config_fields)
    |> update_change(:executable_path, &String.trim(&1 || ""))
    |> validate_required(@config_fields)
    |> cast_embed(:models)
    |> unique_constraint(:name)
  end

  @doc """
  Builds a changeset for what a usage probe reports. It never touches the
  executable path or the models, so a refresh cannot clobber the user's config.
  """
  def usage_changeset(backend, attrs) do
    backend
    |> cast(attrs, @usage_fields)
    |> validate_required([:name, :status])
    |> cast_embed(:usage, with: &usage_group_changeset/2)
    |> unique_constraint(:name)
  end

  defp usage_group_changeset(usage, attrs) do
    usage
    |> cast(attrs, [:name, :count, :details])
    |> validate_required([:name])
    |> validate_number(:count, greater_than_or_equal_to: 0)
  end
end

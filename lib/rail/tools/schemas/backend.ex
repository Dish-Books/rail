defmodule Rail.Tools.Schemas.Backend do
  @moduledoc """
  Schema for a CLI backend: where its executable lives, which models may be
  selected for it, and what the last usage probe found out about the account
  signed in to it.
  """
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @names [:claude]
  @statuses [:not_configured, :signed_out, :unavailable, :ready]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bkd"}
  schema "backends" do
    field :name, Ecto.Enum, values: @names
    # Tells apart two backends of the same kind, e.g. a work and a personal account.
    field :label, :string
    field :executable_path, :string, default: ""
    # A model the user has made available on this backend.
    embeds_many :models, Model, primary_key: false, on_replace: :delete do
      @derive Jason.Encoder
      field :id, :string
      field :display_name, :string
    end

    field :status, Ecto.Enum, values: @statuses, default: :not_configured
    field :account_label, :string
    field :account_detail, :string
    field :fetched_at, :utc_datetime_usec
    field :unavailable_reason, :string
    # The long-lived token `claude setup-token` issues, handed to the CLI as
    # CLAUDE_CODE_OAUTH_TOKEN. Nothing refreshes or rotates it, so no CLI can lose it.
    field :oauth_token, EncryptedBinary, redact: true
    # When the backend stopped being signed in with nobody having signed it out:
    # its token was rejected, or a probe found a ready one signed out. Cleared
    # once its token is replaced or removed.
    field :session_lost_at, :utc_datetime_usec

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

  @config_fields [:name, :label, :executable_path]
  @required_config_fields [:name, :executable_path]
  @usage_fields [
    :name,
    :status,
    :account_label,
    :account_detail,
    :fetched_at,
    :unavailable_reason,
    :session_lost_at
  ]

  @doc "Returns the backends that can be configured."
  def names, do: @names

  @doc "Returns the statuses a usage probe can report."
  def statuses, do: @statuses

  @doc """
  Returns the environment variable a backend's CLI reads its config directory
  from.
  """
  def env_var(:claude), do: "CLAUDE_CONFIG_DIR"

  @doc """
  Returns the directory a backend's CLI keeps its signed-in account in. It is
  Rail's, one per backend, so no two backends can share an account by accident
  and none touches the account the CLI uses outside Rail.
  """
  def config_dir(%__MODULE__{id: id}) when is_binary(id) do
    root = Application.get_env(:rail, :backends_root) || Path.join(System.user_home!(), ".rail/backends")
    Path.join(root, id)
  end

  @doc """
  Builds a changeset for the configuration the user owns: the label, the
  executable path and the models selectable on it.
  """
  def changeset(backend, attrs) do
    backend
    |> cast(attrs, @config_fields)
    |> update_change(:executable_path, &String.trim(&1 || ""))
    |> update_change(:label, &String.trim/1)
    |> validate_required(@required_config_fields)
    |> cast_embed(:models, with: &model_changeset/2)
  end

  @doc """
  Builds a changeset that replaces the backend's token, or removes it with nil.
  A new token has not been rejected yet, so the lost session is forgotten.
  """
  def token_changeset(backend, token) do
    change(backend, oauth_token: token, session_lost_at: nil)
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
  end

  # A model with no display name shows as its id rather than as nothing.
  defp model_changeset(model, attrs) do
    model
    |> cast(attrs, [:id, :display_name])
    |> update_change(:id, &String.trim/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:id])
    |> default_display_name()
  end

  defp default_display_name(changeset) do
    case get_field(changeset, :display_name) do
      name when is_binary(name) and name != "" -> changeset
      _blank -> put_change(changeset, :display_name, get_field(changeset, :id))
    end
  end

  defp usage_group_changeset(usage, attrs) do
    usage
    |> cast(attrs, [:name, :count, :details])
    |> validate_required([:name])
    |> validate_number(:count, greater_than_or_equal_to: 0)
  end
end

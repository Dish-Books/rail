defmodule Rail.Users.Schemas.User do
  @moduledoc false
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @primary_key {:id, UXID, autogenerate: true, prefix: "usr"}
  schema "users" do
    field :github_id, :string
    field :login, :string
    field :name, :string
    field :email, :string
    field :avatar_url, :string
    field :admin, :boolean, default: false
    # Approves and merges tasks from Finalize, which admins alone may not.
    field :tech_lead, :boolean, default: false
    field :project_ids, {:array, :string}, default: []
    field :github_token, EncryptedBinary, redact: true
    field :github_refresh_token, EncryptedBinary, redact: true
    field :github_token_expires_at, :utc_datetime_usec
    field :linear_user_id, :string
    field :linear_name, :string
    field :linear_access_token, EncryptedBinary, redact: true
    field :linear_refresh_token, EncryptedBinary, redact: true
    field :linear_token_expires_at, :utc_datetime_usec
    field :slack_user_id, :string
    field :slack_team_id, :string
    field :slack_name, :string
    field :slack_access_token, EncryptedBinary, redact: true
    # Only `slack_notifications_changeset/2` turns it on, so an admin editing a user cannot.
    field :slack_notifications, :boolean, default: false
    # The Issues page's filters as the URL parameters that set them; only `issues_filters_changeset/2` writes it.
    field :issues_filters, :map, default: %{}
    field :signing_key, EncryptedBinary, redact: true
    field :signing_public_key, :string
    field :signing_key_github_id, :integer

    has_many :tokens, Rail.Users.Schemas.UserToken, on_delete: :delete_all

    timestamps()
  end

  @issues_filter_keys ["priority", "mine", "finished", "cycle", "owner"]

  @updatable_fields [
    :github_id,
    :login,
    :name,
    :email,
    :avatar_url,
    :admin,
    :tech_lead,
    :project_ids,
    :github_token,
    :github_refresh_token,
    :github_token_expires_at,
    :linear_user_id,
    :linear_name,
    :linear_access_token,
    :linear_refresh_token,
    :linear_token_expires_at,
    :slack_user_id,
    :slack_team_id,
    :slack_name,
    :slack_access_token,
    :signing_key,
    :signing_public_key,
    :signing_key_github_id
  ]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @updatable_fields)
    # A form of checkboxes sends a blank alongside the ticked ones.
    |> update_change(:project_ids, &(&1 |> Enum.reject(fn id -> id == "" end) |> Enum.uniq()))
    |> validate_required([:github_id, :login, :email])
    |> unique_constraint(:github_id)
    |> unique_constraint(:login)
    |> unique_constraint(:email)
    # Removing the Slack link turns notifications off, forced so a stale struct that still reads off clears them too.
    |> then(
      &if(fetch_change(&1, :slack_user_id) == {:ok, nil}, do: force_change(&1, :slack_notifications, false), else: &1)
    )
  end

  @doc """
  Turns the user's Slack notifications on or off, refusing on for someone with no Slack account to message.
  """
  def slack_notifications_changeset(user, attrs) do
    changeset = user |> cast(attrs, [:slack_notifications]) |> validate_required([:slack_notifications])

    if get_field(changeset, :slack_notifications) == true and is_nil(get_field(changeset, :slack_user_id)),
      do: add_error(changeset, :slack_notifications, "connect Slack first"),
      else: changeset
  end

  @doc """
  Replaces the Issues filters the user last set, keeping only the remembered keys with string values.
  """
  def issues_filters_changeset(user, attrs) do
    user
    |> cast(attrs, [:issues_filters])
    |> validate_required([:issues_filters])
    |> update_change(
      :issues_filters,
      &Map.filter(Map.take(&1, @issues_filter_keys), fn {_key, value} -> is_binary(value) end)
    )
  end

  @doc """
  True when this user has a signing key Rail can commit with.
  """
  def signing?(%__MODULE__{signing_key: key}) when is_binary(key), do: true
  def signing?(%__MODULE__{}), do: false

  @doc """
  The signing key's fingerprint, as GitHub shows it, or nil when there is none.

  The public key is stored as an OpenSSH `ssh-ed25519 <base64> <comment>`
  line, so the fingerprint is the sha256 of the decoded blob.
  """
  def signing_fingerprint(%__MODULE__{signing_public_key: line}) when is_binary(line) do
    case String.split(line, " ") do
      [_type, blob | _comment] ->
        digest = :sha256 |> :crypto.hash(Base.decode64!(blob)) |> Base.encode64(padding: false)
        "SHA256:" <> digest

      _malformed ->
        nil
    end
  end

  def signing_fingerprint(%__MODULE__{}), do: nil
end

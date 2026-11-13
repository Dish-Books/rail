defmodule Rail.Repo.Migrations.CreateOauthTables do
  use Ecto.Migration

  def change do
    create table(:oauth_clients) do
      add :name, :text, null: false
      add :client_id, :text, null: false
      # Public clients hold no secret.
      add :client_secret_hash, :binary
      add :redirect_uris, {:array, :text}, null: false
      add :registration, :text, null: false
      add :token_endpoint_auth_method, :text, null: false
      add :metadata_fetched_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:oauth_clients, [:client_id])

    create table(:oauth_authorization_codes) do
      add :oauth_client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :selector, :text, null: false
      add :verifier_hash, :binary, null: false
      add :redirect_uri, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      # The family its tokens share, so replaying the consumed code can revoke every token minted from it.
      add :family_id, :text, null: false
      add :code_challenge, :text, null: false

      timestamps()
    end

    create unique_index(:oauth_authorization_codes, [:selector])
    create unique_index(:oauth_authorization_codes, [:family_id])
    create index(:oauth_authorization_codes, [:oauth_client_id])
    create index(:oauth_authorization_codes, [:user_id])

    create table(:oauth_access_tokens) do
      add :oauth_client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :selector, :text, null: false
      add :verifier_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :family_id, :text, null: false

      timestamps()
    end

    create unique_index(:oauth_access_tokens, [:selector])
    create index(:oauth_access_tokens, [:family_id])
    create index(:oauth_access_tokens, [:user_id])
    create index(:oauth_access_tokens, [:oauth_client_id])

    create table(:oauth_refresh_tokens) do
      add :oauth_client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :access_token_id, references(:oauth_access_tokens, on_delete: :delete_all), null: false
      add :selector, :text, null: false
      add :verifier_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :family_id, :text, null: false

      timestamps()
    end

    create unique_index(:oauth_refresh_tokens, [:selector])
    create index(:oauth_refresh_tokens, [:family_id])
    create index(:oauth_refresh_tokens, [:oauth_client_id])
    create index(:oauth_refresh_tokens, [:user_id])
    create index(:oauth_refresh_tokens, [:access_token_id])
  end
end

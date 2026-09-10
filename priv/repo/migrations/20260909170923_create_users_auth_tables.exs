defmodule Rail.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users) do
      add :github_id, :text, null: false
      add :login, :text, null: false
      add :name, :text
      add :email, :citext, null: false
      add :avatar_url, :text
      add :admin, :boolean, default: false, null: false
      add :github_token, :binary
      add :linear_user_id, :text
      add :linear_name, :text
      add :linear_access_token, :binary
      add :linear_refresh_token, :binary
      add :linear_token_expires_at, :utc_datetime_usec
      add :last_project_filter, :text

      timestamps()
    end

    create unique_index(:users, [:github_id])
    create unique_index(:users, [:login])
    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :text, null: false
      add :sent_to, :text

      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end

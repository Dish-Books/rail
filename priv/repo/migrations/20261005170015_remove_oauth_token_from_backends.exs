defmodule Rail.Repo.Migrations.RemoveOauthTokenFromBackends do
  use Ecto.Migration

  # Backends sign in through the Claude CLI again, so no pasted token is kept.
  def up do
    alter table(:backends) do
      remove :oauth_token
    end
  end

  def down do
    alter table(:backends) do
      add :oauth_token, :binary
    end
  end
end

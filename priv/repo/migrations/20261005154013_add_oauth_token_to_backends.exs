defmodule Rail.Repo.Migrations.AddOauthTokenToBackends do
  use Ecto.Migration

  def change do
    alter table(:backends) do
      add :oauth_token, :binary
    end
  end
end

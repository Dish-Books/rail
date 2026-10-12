defmodule Rail.Repo.Migrations.AddGithubRefreshTokenToUsers do
  @moduledoc false
  use Ecto.Migration

  # A GitHub App's sign-in token lasts 8 hours; the refresh token renews it, and the expiry says when to.
  def change do
    alter table(:users) do
      add :github_refresh_token, :binary
      add :github_token_expires_at, :utc_datetime_usec
    end
  end
end

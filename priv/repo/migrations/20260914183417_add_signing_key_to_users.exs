defmodule Rail.Repo.Migrations.AddSigningKeyToUsers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :signing_key, :binary
      add :signing_public_key, :text
      add :signing_key_github_id, :bigint
    end
  end
end

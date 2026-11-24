defmodule Rail.Repo.Migrations.AddRemovedAtToUsers do
  use Ecto.Migration

  # A removed user keeps their row, so their name stays on the work they did.
  def change do
    alter table(:users) do
      add :removed_at, :utc_datetime_usec
    end
  end
end

defmodule Rail.Repo.Migrations.CreateRestarts do
  use Ecto.Migration

  def change do
    create table(:restarts) do
      add :stopped_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :sandboxes_kept, :integer

      timestamps()
    end
  end
end

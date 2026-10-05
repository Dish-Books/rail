defmodule Rail.Repo.Migrations.AddSessionLostAtToBackends do
  use Ecto.Migration

  def change do
    alter table(:backends) do
      add :session_lost_at, :utc_datetime_usec
    end
  end
end

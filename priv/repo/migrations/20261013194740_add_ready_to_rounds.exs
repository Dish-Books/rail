defmodule Rail.Repo.Migrations.AddReadyToRounds do
  use Ecto.Migration

  # When a round's plan was sent to a tech lead, and by whom.
  def change do
    alter table(:rounds) do
      add :ready_at, :utc_datetime_usec
      add :ready_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end

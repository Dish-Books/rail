defmodule Rail.Repo.Migrations.AddWaitStartedAtToRuns do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add :wait_started_at, :utc_datetime_usec
    end

    flush()

    # A run at rest today has a wait id from the start, so a client's first call after the deploy matches its next.
    execute "UPDATE runs SET wait_started_at = COALESCE(completed_at, updated_at)"
  end

  def down do
    alter table(:runs) do
      remove :wait_started_at
    end
  end
end

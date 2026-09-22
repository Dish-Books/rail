defmodule Rail.Repo.Migrations.AddTaskDemoSkippedAt do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :demo_skipped_at, :utc_datetime_usec
    end
  end
end

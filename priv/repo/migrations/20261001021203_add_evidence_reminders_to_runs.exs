defmodule Rail.Repo.Migrations.AddEvidenceRemindersToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :evidence_reminders, :integer, default: 0, null: false
    end
  end
end

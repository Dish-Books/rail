defmodule Rail.Repo.Migrations.RemoveEvidenceRemindersFromRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      remove :evidence_reminders, :integer, default: 0, null: false
    end
  end
end

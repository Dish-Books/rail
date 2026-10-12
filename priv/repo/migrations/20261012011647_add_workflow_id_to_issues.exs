defmodule Rail.Repo.Migrations.AddWorkflowIdToIssues do
  use Ecto.Migration

  # The workflow that opened the issue, or nil for one somebody filed.
  def change do
    alter table(:issues) do
      add :workflow_id, references(:workflows)
    end
  end
end

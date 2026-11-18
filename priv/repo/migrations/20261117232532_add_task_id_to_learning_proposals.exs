defmodule Rail.Repo.Migrations.AddTaskIdToLearningProposals do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:learning_proposals) do
      # A deleted task's proposals stay on the Learnings page, with no task.
      add :task_id, references(:tasks, on_delete: :nilify_all)
    end

    create index(:learning_proposals, [:task_id], concurrently: true)
  end
end

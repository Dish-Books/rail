defmodule Rail.Repo.Migrations.IndexTaskWorktreeSlot do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A slot is a block of ports on this machine, so no two tasks may hold one at
  # once, whichever project they belong to.
  def change do
    create unique_index(:tasks, [:worktree_slot],
             where: "worktree_slot IS NOT NULL",
             name: :tasks_worktree_slot_index,
             concurrently: true
           )
  end
end

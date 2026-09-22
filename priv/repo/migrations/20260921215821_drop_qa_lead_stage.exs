defmodule Rail.Repo.Migrations.DropQaLeadStage do
  use Ecto.Migration

  # `:qa_lead` was a stage nothing entered and nothing left: an enum value and a
  # seeded role with a placeholder brief, sitting between QA and demo. Both stage
  # columns are text, so there is no type to change - only the rows that were
  # parked on it.
  #
  # A task there is sent back to QA rather than forward to demo. It never had a
  # pass of its own, so QA is where it last actually got to.
  def up do
    execute "UPDATE tasks SET stage = 'qa' WHERE stage = 'qa_lead'"
    execute "DELETE FROM roles WHERE stage = 'qa_lead'"
  end

  def down do
    raise Ecto.MigrationError,
      message: "The QA Lead stage cannot be restored: the roles bound to it were deleted."
  end
end

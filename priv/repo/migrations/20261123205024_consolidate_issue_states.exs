defmodule Rail.Repo.Migrations.ConsolidateIssueStates do
  use Ecto.Migration

  # Triage and Backlog fold into Todo, and Duplicate into Canceled.
  def up do
    for table <- ["issues", "closed_cycle_issues"] do
      execute "UPDATE #{table} SET state = 'todo' WHERE state IN ('triage', 'backlog')"
      execute "UPDATE #{table} SET state = 'canceled' WHERE state = 'duplicate'"
    end
  end

  # Which tickets were in Triage, Backlog or Duplicate is not kept, so there is nothing to put back.
  def down, do: :ok
end

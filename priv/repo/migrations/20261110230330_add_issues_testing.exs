defmodule Rail.Repo.Migrations.AddIssuesTesting do
  @moduledoc false
  use Ecto.Migration

  # Every ticket starts Waiting. Those already in Done go back to NULL, since the ticket keeps them out of the queue.
  def up do
    alter table(:issues) do
      add :testing_state, :text, default: "waiting"
      add :testing_notes, :text
    end

    execute("UPDATE issues SET testing_state = NULL WHERE state = 'done'")
  end

  def down do
    alter table(:issues) do
      remove :testing_state
      remove :testing_notes
    end
  end
end

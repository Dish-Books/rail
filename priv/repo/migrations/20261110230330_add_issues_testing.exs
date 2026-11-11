defmodule Rail.Repo.Migrations.AddIssuesTesting do
  @moduledoc false
  use Ecto.Migration

  # Every ticket starts Waiting, those already in Done included, so they join the testing queue.
  def change do
    alter table(:issues) do
      add :testing_state, :text, null: false, default: "waiting"
      add :testing_notes, :text
    end
  end
end

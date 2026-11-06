defmodule Rail.Repo.Migrations.AddSkippedStepsToIssues do
  @moduledoc false
  use Ecto.Migration

  # The steps a workflow turned off for the issue's tasks; every existing issue keeps every step.
  def change do
    alter table(:issues) do
      add :skipped_steps, {:array, :text}, null: false, default: []
    end
  end
end

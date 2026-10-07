defmodule Rail.Repo.Migrations.AddIssueEstimateToTriageItems do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:triage_items) do
      add :issue_estimate, :integer
    end
  end
end

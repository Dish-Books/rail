defmodule Rail.Repo.Migrations.AddEstimateToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :estimate, :integer
    end
  end
end

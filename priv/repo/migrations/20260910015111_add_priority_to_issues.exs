defmodule Rail.Repo.Migrations.AddPriorityToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :priority, :text, default: "medium", null: false
    end
  end
end

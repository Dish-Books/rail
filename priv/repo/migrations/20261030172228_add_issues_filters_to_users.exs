defmodule Rail.Repo.Migrations.AddIssuesFiltersToUsers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :issues_filters, :map, null: false, default: %{}
    end
  end
end

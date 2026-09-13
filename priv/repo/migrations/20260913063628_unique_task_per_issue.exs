defmodule Rail.Repo.Migrations.UniqueTaskPerIssue do
  @moduledoc false
  use Ecto.Migration

  def change do
    drop index(:tasks, [:issue_id])
    create unique_index(:tasks, [:issue_id])
  end
end

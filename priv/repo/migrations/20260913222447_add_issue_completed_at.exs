defmodule Rail.Repo.Migrations.AddIssueCompletedAt do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :completed_at, :utc_datetime
    end

    create index(:issues, [:project_id, :completed_at])
  end
end

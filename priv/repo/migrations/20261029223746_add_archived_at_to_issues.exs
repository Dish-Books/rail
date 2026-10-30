defmodule Rail.Repo.Migrations.AddArchivedAtToIssues do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :archived_at, :utc_datetime
    end
  end
end

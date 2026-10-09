defmodule Rail.Repo.Migrations.AddLinearUpdatedAtToIssues do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :linear_updated_at, :utc_datetime_usec
    end
  end
end

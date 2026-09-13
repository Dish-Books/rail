defmodule Rail.Repo.Migrations.DropIssueLinearTimestamps do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      remove :linear_created_at, :utc_datetime_usec
      remove :linear_updated_at, :utc_datetime_usec
    end
  end
end

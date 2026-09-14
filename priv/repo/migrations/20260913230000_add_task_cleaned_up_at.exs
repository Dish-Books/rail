defmodule Rail.Repo.Migrations.AddTaskCleanedUpAt do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :cleaned_up_at, :utc_datetime_usec
    end

    # A cleaned-up task is kept as history, so only the live task is unique per issue.
    drop unique_index(:tasks, [:issue_id])
    create unique_index(:tasks, [:issue_id], where: "cleaned_up_at IS NULL")
  end
end

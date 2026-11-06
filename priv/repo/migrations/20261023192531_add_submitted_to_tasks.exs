defmodule Rail.Repo.Migrations.AddSubmittedToTasks do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :submitted_by_id, references(:users, on_delete: :nilify_all)
      add :submitted_at, :utc_datetime_usec
      add :submitted_head, :text
    end
  end
end

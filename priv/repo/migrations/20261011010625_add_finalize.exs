defmodule Rail.Repo.Migrations.AddFinalize do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tech_lead, :boolean, default: false, null: false
    end

    # A user who leaves takes their name off the record, not the record itself.
    alter table(:tasks) do
      add :marked_ready_by_id, references(:users, on_delete: :nilify_all)
      add :marked_ready_at, :utc_datetime_usec
      add :merge_started_at, :utc_datetime_usec
      add :merge_error, :text
      add :merge_error_at, :utc_datetime_usec
      add :merged_by_id, references(:users, on_delete: :nilify_all)
      add :merge_sha, :text
    end
  end
end

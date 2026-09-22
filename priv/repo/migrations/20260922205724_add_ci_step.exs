defmodule Rail.Repo.Migrations.AddCiStep do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :ci_command, :text
      add :ci_timeout_minutes, :integer, default: 30, null: false
    end

    alter table(:runs) do
      add :ci_failure_streak, :integer, default: 0, null: false
    end

    alter table(:os_processes) do
      add :head_sha, :text
    end
  end
end

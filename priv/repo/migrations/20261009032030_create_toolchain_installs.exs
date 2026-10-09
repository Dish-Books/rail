defmodule Rail.Repo.Migrations.CreateToolchainInstalls do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :toolchain_command, :text
    end

    create table(:toolchain_installs) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :command, :text, null: false
      add :head_sha, :text, null: false
      add :status, :text, null: false
      add :output, :text
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps()
    end

    create index(:toolchain_installs, [:project_id])
    create index(:toolchain_installs, [:status])

    alter table(:os_processes) do
      add :memory_top, {:array, :map}
    end
  end
end

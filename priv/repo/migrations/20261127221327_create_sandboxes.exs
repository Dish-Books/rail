defmodule Rail.Repo.Migrations.CreateSandboxes do
  use Ecto.Migration

  def change do
    create table(:sandboxes) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :host, :text, null: false, default: "local"
      add :engine, :text, null: false
      add :image, :text, null: false
      add :volume, :text, null: false
      add :status, :text, null: false
      add :container_id, :text
      add :backend_id, references(:backends, on_delete: :nilify_all)
      add :token_hash, :binary
      add :runner_version, :text
      add :started_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
      add :ready_at, :utc_datetime_usec
      add :stopped_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps()
    end

    # A task has one sandbox at a time; an ended one stays for the record.
    create unique_index(:sandboxes, [:task_id], where: "status != 'ended'")
    create index(:sandboxes, [:host, :status])
    create unique_index(:sandboxes, [:token_hash])

    alter table(:os_processes) do
      add :sandbox_id, references(:sandboxes, on_delete: :nilify_all)
    end

    create index(:os_processes, [:sandbox_id, :status])

    alter table(:projects) do
      add :sandbox_image, :text
    end
  end
end

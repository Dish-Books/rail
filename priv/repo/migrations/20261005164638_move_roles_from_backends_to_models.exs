defmodule Rail.Repo.Migrations.MoveRolesFromBackendsToModels do
  use Ecto.Migration

  def up do
    alter table(:roles) do
      add :cli, :text
    end

    alter table(:os_processes) do
      add :backend_id, references(:backends)
    end

    # Every role keeps its model and the CLI it ran on.
    execute "UPDATE roles SET cli = backends.name FROM backends WHERE backends.id = roles.backend_id"

    # A conversation already open lives on the account its role was pinned to, so it stays there.
    execute """
    UPDATE os_processes SET backend_id = roles.backend_id
    FROM runs JOIN roles ON roles.id = runs.role_id
    WHERE runs.id = os_processes.run_id AND os_processes.kind = 'agent'
    """

    execute "ALTER TABLE roles ALTER COLUMN cli SET NOT NULL"

    drop_if_exists index(:roles, [:backend_id])

    alter table(:roles) do
      remove :backend_id
    end
  end

  def down do
    alter table(:roles) do
      add :backend_id, references(:backends, on_delete: :restrict)
    end

    execute """
    UPDATE roles SET backend_id = (
      SELECT id FROM backends WHERE backends.name = roles.cli ORDER BY inserted_at, id LIMIT 1
    )
    """

    create index(:roles, [:backend_id])

    alter table(:os_processes) do
      remove :backend_id
    end

    alter table(:roles) do
      remove :cli
    end
  end
end

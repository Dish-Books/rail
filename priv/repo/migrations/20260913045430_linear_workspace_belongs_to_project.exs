defmodule Rail.Repo.Migrations.LinearWorkspaceBelongsToProject do
  use Ecto.Migration

  def up do
    alter table(:linear_workspaces) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all)
    end

    execute """
    UPDATE linear_workspaces lw
    SET project_id = (SELECT p.id FROM projects p WHERE p.linear_workspace_id = lw.id LIMIT 1)
    """

    create unique_index(:linear_workspaces, [:project_id])

    drop index(:projects, [:linear_workspace_id])

    alter table(:projects) do
      remove :linear_workspace_id
    end
  end

  def down do
    alter table(:projects) do
      add :linear_workspace_id, references(:linear_workspaces, type: :text, on_delete: :nilify_all)
    end

    create index(:projects, [:linear_workspace_id])

    execute """
    UPDATE projects p
    SET linear_workspace_id = (SELECT lw.id FROM linear_workspaces lw WHERE lw.project_id = p.id LIMIT 1)
    """

    drop unique_index(:linear_workspaces, [:project_id])

    alter table(:linear_workspaces) do
      remove :project_id
    end
  end
end

defmodule Rail.Repo.Migrations.ProjectsShareLinearWorkspaces do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :linear_workspace_id, references(:linear_workspaces)
    end

    execute """
    UPDATE projects p
    SET linear_workspace_id = lw.id
    FROM linear_workspaces lw
    WHERE lw.project_id = p.id
    """

    alter table(:linear_workspaces) do
      remove :project_id
    end
  end

  # A workspace shared by several projects goes back to one of them.
  def down do
    alter table(:linear_workspaces) do
      add :project_id, references(:projects, on_delete: :delete_all)
    end

    execute """
    UPDATE linear_workspaces lw
    SET project_id = (SELECT p.id FROM projects p WHERE p.linear_workspace_id = lw.id ORDER BY p.inserted_at LIMIT 1)
    """

    create unique_index(:linear_workspaces, [:project_id])

    alter table(:projects) do
      remove :linear_workspace_id
    end
  end
end

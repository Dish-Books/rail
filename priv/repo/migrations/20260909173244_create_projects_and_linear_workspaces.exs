defmodule Rail.Repo.Migrations.CreateProjectsAndLinearWorkspaces do
  use Ecto.Migration

  def change do
    create table(:linear_workspaces) do
      add :name, :text, null: false
      add :external_id, :text, null: false
      add :token, :binary, null: false
      add :webhook_secret, :binary, null: false

      timestamps()
    end

    create unique_index(:linear_workspaces, [:external_id])

    create table(:projects) do
      add :name, :text, null: false
      add :github_repo, :text, null: false
      add :github_installation_id, :bigint, null: false
      add :default_branch, :text, default: "main", null: false
      add :linear_workspace_id, references(:linear_workspaces, on_delete: :nilify_all)
      add :linear_team_id, :text, null: false
      add :linear_team_key, :text, null: false
      add :linear_state_ids, :map, default: %{}, null: false
      add :clone_path, :text, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:projects, [:github_repo])
    create index(:projects, [:linear_workspace_id])
  end
end

defmodule Rail.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :stage, :text
      add :name, :text, null: false
      add :description, :text
      add :icon_name, :text
      add :cli_backend, :text, default: "claude", null: false
      add :model, :text, null: false
      add :reasoning_effort, :text
      add :system_prompt, :text, null: false
      add :max_concurrent, :integer, default: 1, null: false
      add :position, :integer, default: 0, null: false

      timestamps()
    end

    create index(:roles, [:project_id])
    create unique_index(:roles, [:project_id, :stage], where: "stage IS NOT NULL", name: :roles_project_id_stage_index)
  end
end

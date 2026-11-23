defmodule Rail.Repo.Migrations.CreateLinearFileCopies do
  use Ecto.Migration

  def change do
    create table(:linear_file_copies) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :issue_external_id, :text, null: false
      add :issue_id, :text, null: false
      add :identifier, :text
      add :url, :text, null: false
      add :state, :text, null: false, default: "pending"
      add :copied_url, :text
      add :error, :text
      timestamps()
    end

    create unique_index(:linear_file_copies, [:project_id, :issue_external_id, :url])
  end
end

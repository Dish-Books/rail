defmodule Rail.Repo.Migrations.CreateDiffComments do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:diff_comments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :line_kind, :text, null: false
      add :line, :integer, null: false
      add :line_text, :text, null: false
      add :filter, :text, null: false
      add :body, :text, null: false

      timestamps()
    end

    create index(:diff_comments, [:task_id, :user_id])
  end
end

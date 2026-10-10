defmodule Rail.Repo.Migrations.CreateScreenComments do
  use Ecto.Migration

  # One person's comment on one screen state Review shot, kept by the state's key since a retake replaces its picture.
  def change do
    create table(:screen_comments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :label, :text, null: false
      add :commit, :text
      add :body, :text, null: false
      add :status, :text, null: false, default: "unsent"

      timestamps()
    end

    create index(:screen_comments, [:task_id, :user_id])
  end
end

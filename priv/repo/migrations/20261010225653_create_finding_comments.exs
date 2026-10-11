defmodule Rail.Repo.Migrations.CreateFindingComments do
  use Ecto.Migration

  # One person's comment on one piece of a Review finding, quoting the piece as it read when it was written.
  def change do
    create table(:finding_comments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :finding_id, references(:findings, on_delete: :delete_all), null: false
      add :piece, :text, null: false
      add :index, :integer
      add :label, :text, null: false
      add :quote, :text, null: false
      add :body, :text, null: false
      add :status, :text, null: false, default: "unsent"

      timestamps()
    end

    create index(:finding_comments, [:task_id, :user_id])
    create index(:finding_comments, [:finding_id])
  end
end

defmodule Rail.Repo.Migrations.CreatePlanComments do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:plan_comments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :target, :text, null: false
      add :status, :text, default: "unsent", null: false
      add :body, :text, null: false
      add :option_key, :text
      add :selector, :text
      add :element_text, :text
      add :element_tag, :text
      add :capture, :map

      timestamps()
    end

    create index(:plan_comments, [:task_id, :user_id])
  end
end

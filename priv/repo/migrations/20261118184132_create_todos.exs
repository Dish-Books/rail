defmodule Rail.Repo.Migrations.CreateTodos do
  use Ecto.Migration

  def change do
    create table(:todos) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :url, :text
      add :position, :integer, null: false
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:todos, [:user_id])
  end
end

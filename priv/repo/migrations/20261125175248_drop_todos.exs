defmodule Rail.Repo.Migrations.DropTodos do
  use Ecto.Migration

  # The to-dos panel is gone. A database that ran the unmerged RAIL-188 branch dropped the table already. The table
  # comes back empty on a rollback: what it held is gone.
  def up do
    drop_if_exists table(:todos)
  end

  def down do
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

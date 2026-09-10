defmodule Rail.Repo.Migrations.CreateBackends do
  use Ecto.Migration

  def change do
    create table(:backends) do
      add :name, :text, null: false
      add :executable_path, :text, null: false
      add :models, :jsonb, default: "[]", null: false

      timestamps()
    end

    create unique_index(:backends, [:name])
  end
end

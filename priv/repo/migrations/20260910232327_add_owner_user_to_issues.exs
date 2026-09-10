defmodule Rail.Repo.Migrations.AddOwnerUserToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :owner_user_id, references(:users, type: :text, on_delete: :nilify_all)
    end

    create index(:issues, [:owner_user_id])
  end
end

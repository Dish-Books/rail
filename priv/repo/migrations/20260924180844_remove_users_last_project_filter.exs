defmodule Rail.Repo.Migrations.RemoveUsersLastProjectFilter do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :last_project_filter, :text
    end
  end
end

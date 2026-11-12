defmodule Rail.Repo.Migrations.AllowUsersWithoutGithub do
  use Ecto.Migration

  def change do
    alter table(:users) do
      modify :github_id, :text, null: true, from: {:text, null: false}
      modify :login, :text, null: true, from: {:text, null: false}
    end
  end
end

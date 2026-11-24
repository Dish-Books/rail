defmodule Rail.Repo.Migrations.AddRoleToUsersAndInvites do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Which tabs the person sees: support, tester or dev. Everyone already here is a dev.
      add :role, :text, null: false, default: "dev"
    end

    alter table(:invites) do
      add :role, :text, null: false, default: "dev"
    end
  end
end

defmodule Rail.Repo.Migrations.AddProjectIdsToUsersAndInvites do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :project_ids, {:array, :text}, default: [], null: false
    end

    alter table(:invites) do
      add :project_ids, {:array, :text}, default: [], null: false
    end

    # Everyone already in, or already invited, keeps seeing every project they see today.
    execute "UPDATE users SET project_ids = ARRAY(SELECT id FROM projects ORDER BY inserted_at)"

    execute """
    UPDATE invites SET project_ids = ARRAY(SELECT id FROM projects ORDER BY inserted_at)
    WHERE accepted_at IS NULL
    """
  end

  def down do
    alter table(:invites) do
      remove :project_ids
    end

    alter table(:users) do
      remove :project_ids
    end
  end
end

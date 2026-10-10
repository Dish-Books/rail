defmodule Rail.Repo.Migrations.FoldLinearTeamKeyIntoKey do
  use Ecto.Migration

  # Every project has one key: a Linear project's team key, or the prefix a GitHub project names its issues with.
  def up do
    execute "UPDATE projects SET key = linear_team_key WHERE tracker = 'linear'"
    drop constraint(:projects, :linear_projects_have_team_key)

    alter table(:projects) do
      remove :linear_team_key
      modify :key, :citext, null: false, from: {:citext, null: true}
    end
  end

  def down do
    alter table(:projects) do
      add :linear_team_key, :text
      modify :key, :citext, null: true, from: {:citext, null: false}
    end

    execute "UPDATE projects SET linear_team_key = key, key = NULL WHERE tracker = 'linear'"

    create constraint(:projects, :linear_projects_have_team_key,
             check: "tracker <> 'linear' OR linear_team_key IS NOT NULL"
           )
  end
end

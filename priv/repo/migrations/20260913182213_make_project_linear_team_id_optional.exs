defmodule Rail.Repo.Migrations.MakeProjectLinearTeamIdOptional do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:projects) do
      modify :linear_team_id, :text, null: true, from: {:text, null: false}
    end
  end
end

defmodule Rail.Repo.Migrations.AddExternalToSlackChannels do
  use Ecto.Migration

  # Every channel connected so far was treated as the team's own, so none starts out external.
  def change do
    alter table(:slack_channels) do
      add :external, :boolean, default: false, null: false
    end
  end
end

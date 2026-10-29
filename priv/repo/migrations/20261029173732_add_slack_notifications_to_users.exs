defmodule Rail.Repo.Migrations.AddSlackNotificationsToUsers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :slack_notifications, :boolean, null: false, default: false
    end
  end
end

defmodule Rail.Repo.Migrations.AddSlackSupportNotificationsToUsers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :slack_support_notifications, :boolean, null: false, default: false
    end
  end
end

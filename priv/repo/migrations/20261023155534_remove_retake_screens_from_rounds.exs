defmodule Rail.Repo.Migrations.RemoveRetakeScreensFromRounds do
  use Ecto.Migration

  # QA reads what changed since each state's picture and decides which to shoot again, so a plan no longer asks.
  def change do
    alter table(:rounds) do
      remove :retake_screens, :boolean, null: false, default: false
    end
  end
end

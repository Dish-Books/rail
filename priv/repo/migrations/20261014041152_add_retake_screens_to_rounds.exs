defmodule Rail.Repo.Migrations.AddRetakeScreensToRounds do
  use Ecto.Migration

  def change do
    alter table(:rounds) do
      add :retake_screens, :boolean, null: false, default: false
    end
  end
end

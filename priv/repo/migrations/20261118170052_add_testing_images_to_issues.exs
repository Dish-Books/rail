defmodule Rail.Repo.Migrations.AddTestingImagesToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :testing_images, :jsonb, null: false, default: "[]"
    end
  end
end

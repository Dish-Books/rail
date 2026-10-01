defmodule Rail.Repo.Migrations.AddImagesToTriageMessages do
  use Ecto.Migration

  def change do
    alter table(:triage_messages) do
      add :images, :jsonb, default: "[]", null: false
    end
  end
end

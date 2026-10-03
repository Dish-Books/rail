defmodule Rail.Repo.Migrations.AddStatusToDiffComments do
  use Ecto.Migration

  # Sent comments were deleted until now, so every existing row is unsent.
  def change do
    alter table(:diff_comments) do
      add :status, :text, default: "unsent", null: false
    end
  end
end

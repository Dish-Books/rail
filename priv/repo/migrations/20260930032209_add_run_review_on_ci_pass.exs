defmodule Rail.Repo.Migrations.AddRunReviewOnCiPass do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :review_on_ci_pass, :boolean, default: false, null: false
    end
  end
end

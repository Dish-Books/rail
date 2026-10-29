defmodule Rail.Repo.Migrations.AddCustomStageToPlanComments do
  use Ecto.Migration

  def change do
    alter table(:plan_comments) do
      add :custom_stage, :text
    end
  end
end

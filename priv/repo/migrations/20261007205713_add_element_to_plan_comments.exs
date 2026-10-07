defmodule Rail.Repo.Migrations.AddElementToPlanComments do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:plan_comments) do
      add :element_kind, :text
      add :element_occurrence, :integer
      add :element_label, :text
    end
  end
end

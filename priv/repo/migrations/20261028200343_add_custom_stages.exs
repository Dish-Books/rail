defmodule Rail.Repo.Migrations.AddCustomStages do
  @moduledoc false
  use Ecto.Migration

  # An issue a workflow opened keeps its file's stages; every existing issue keeps none, which runs the built-ins.
  def change do
    alter table(:issues) do
      add :stages, :jsonb, null: false, default: "[]"
    end

    alter table(:roles) do
      add :custom_stage, :text
    end

    alter table(:tasks) do
      add :custom_stage, :text
    end
  end
end

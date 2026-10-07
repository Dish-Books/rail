defmodule Rail.Repo.Migrations.FoldLinearUpdatedAtIntoExternalUpdatedAt do
  use Ecto.Migration

  # Every tracker's own updated_at lives in external_updated_at, Linear's included.
  def up do
    execute "UPDATE issues SET external_updated_at = linear_updated_at WHERE external_updated_at IS NULL"

    alter table(:issues) do
      remove :linear_updated_at
    end
  end

  def down do
    alter table(:issues) do
      add :linear_updated_at, :utc_datetime_usec
    end

    execute "UPDATE issues SET linear_updated_at = external_updated_at WHERE tracker = 'linear'"
  end
end

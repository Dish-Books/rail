defmodule Rail.Repo.Migrations.AddOsProcessStreamOffset do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:os_processes) do
      add :stream_offset, :bigint, null: false, default: 0
    end
  end
end

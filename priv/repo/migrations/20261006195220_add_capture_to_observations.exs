defmodule Rail.Repo.Migrations.AddCaptureToObservations do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:observations) do
      add :capture, :map
    end
  end
end

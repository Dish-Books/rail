defmodule Rail.Repo.Migrations.AllowMultipleBackendsPerName do
  @moduledoc false
  use Ecto.Migration

  def change do
    # Each backend is signed in to its own account, so one kind of CLI can be
    # connected any number of times, told apart by a label.
    alter table(:backends) do
      add :label, :text
    end

    drop unique_index(:backends, [:name])
    create index(:backends, [:name])
  end
end

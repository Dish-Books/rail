defmodule Rail.Repo.Migrations.DropNode do
  use Ecto.Migration

  # Rail runs as one node. The column was there so a reaper could tell its own
  # processes from another machine's, and with one machine every row is its own.
  def up do
    drop index(:os_processes, [:node, :status])
    drop index(:browser_sessions, [:node, :status])

    alter table(:os_processes), do: remove(:node)
    alter table(:browser_sessions), do: remove(:node)
  end

  def down do
    alter table(:os_processes), do: add(:node, :text, null: false, default: "rail@localhost")
    alter table(:browser_sessions), do: add(:node, :text, null: false, default: "rail@localhost")

    create index(:os_processes, [:node, :status])
    create index(:browser_sessions, [:node, :status])
  end
end

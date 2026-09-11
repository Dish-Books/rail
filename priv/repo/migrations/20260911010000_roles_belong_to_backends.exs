defmodule Rail.Repo.Migrations.RolesBelongToBackends do
  @moduledoc """
  A role's CLI backend was an enum naming a `backends` row by convention, so every
  spawn site looked the executable up by name. It becomes a real association.

  Roles naming a backend the user never configured get a row with a blank
  `executable_path`: that is exactly the `{:missing_binary, ...}` case the spawn path
  already reports, rather than a role that cannot be loaded at all.
  """

  use Ecto.Migration

  import Ecto.Query

  alias Rail.Repo

  def up do
    alter table(:roles) do
      add :backend_id, references(:backends, type: :text, on_delete: :restrict)
    end

    flush()

    backfill_missing_backends()

    execute("""
    UPDATE roles
       SET backend_id = backends.id
      FROM backends
     WHERE backends.name = roles.cli_backend
    """)

    alter table(:roles) do
      modify :backend_id, :text, null: false
      remove :cli_backend
    end

    create index(:roles, [:backend_id])
  end

  def down do
    alter table(:roles) do
      add :cli_backend, :text, default: "claude", null: false
    end

    flush()

    execute("""
    UPDATE roles
       SET cli_backend = backends.name
      FROM backends
     WHERE backends.id = roles.backend_id
    """)

    alter table(:roles) do
      remove :backend_id
    end
  end

  defp backfill_missing_backends do
    now = DateTime.utc_now()

    configured =
      Repo.all(from b in "backends", select: b.name)

    unconfigured =
      Repo.all(from r in "roles", distinct: true, select: r.cli_backend)
      |> Enum.reject(&(&1 in configured))

    rows =
      Enum.map(unconfigured, fn name ->
        [
          id: UXID.generate!(prefix: "bkd"),
          name: name,
          executable_path: "",
          models: "[]",
          inserted_at: now,
          updated_at: now
        ]
      end)

    if rows != [] do
      Repo.insert_all("backends", rows)
    end
  end
end

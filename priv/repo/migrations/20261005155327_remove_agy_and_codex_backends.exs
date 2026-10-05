defmodule Rail.Repo.Migrations.RemoveAgyAndCodexBackends do
  use Ecto.Migration

  # Claude Code is the only backend Rail runs, so the rows of the kinds it no
  # longer knows go: a row whose name the schema cannot load would break every
  # read of the table. `roles.backend_id` restricts the delete, so this fails on
  # purpose while a role still points at one of them. Repoint those roles at a
  # Claude backend first, then migrate.
  def up do
    execute "DELETE FROM backends WHERE name IN ('agy', 'codex')"
  end

  def down, do: :ok
end

defmodule Rail.Repo.Migrations.RemoveDebuggerRoles do
  use Ecto.Migration

  # The debugger stage is gone, with its roles and their runs. A rule people set for the debugger alone is retired
  # rather than left with no roles, which would read as every role's. A task still parked at Debugger would be left
  # at a stage Rail no longer knows, so the deploy waits until none is.
  def up do
    %{rows: parked} = repo().query!("SELECT id FROM tasks WHERE stage = 'debugger' ORDER BY id")

    if parked != [] do
      raise Ecto.MigrationError,
        message: "Move these tasks off the Debugger stage before deploying: " <> Enum.map_join(parked, ", ", &hd/1)
    end

    execute """
    DELETE FROM runs USING roles
    WHERE roles.id = runs.role_id AND roles.stage = 'debugger'
    """

    execute "DELETE FROM roles WHERE stage = 'debugger'"

    execute """
    UPDATE learnings
    SET status = CASE WHEN roles = ARRAY['debugger'] THEN 'retired' ELSE status END,
        retired_at = CASE WHEN roles = ARRAY['debugger'] THEN now() AT TIME ZONE 'utc' ELSE retired_at END,
        roles = array_remove(roles, 'debugger')
    WHERE roles && ARRAY['debugger']
    """
  end

  def down do
    raise Ecto.MigrationError, message: "The debugger role is gone, with its runs and which rule was whose."
  end
end

defmodule Rail.Repo.Migrations.RemoveScreensRoles do
  use Ecto.Migration

  # QA shoots the screen states itself now, so the screenshots role is gone with its runs, and the rules people set
  # for it are QA's. The pictures it saved stay, since they are files under each task's scratch folder.
  # A run still going would outlive its row, so the deploy waits until none is.
  def up do
    %{rows: in_flight} =
      repo().query!("""
      SELECT DISTINCT r.task_id
      FROM runs r
      JOIN roles role ON role.id = r.role_id AND role.stage = 'screens'
      WHERE r.status IN ('starting', 'running', 'waiting_for_resources')
      ORDER BY r.task_id
      """)

    if in_flight != [] do
      raise Ecto.MigrationError,
        message: "Stop the screenshots runs still going on these tasks before deploying: " <> Enum.map_join(in_flight, ", ", &hd/1)
    end

    execute """
    DELETE FROM runs USING roles
    WHERE roles.id = runs.role_id AND roles.stage = 'screens'
    """

    execute "DELETE FROM roles WHERE stage = 'screens'"

    execute """
    UPDATE learnings
    SET roles = ARRAY(
      SELECT DISTINCT CASE WHEN role = 'screens' THEN 'qa' ELSE role END
      FROM unnest(roles) AS role
    )
    WHERE roles && ARRAY['screens']
    """
  end

  def down do
    raise Ecto.MigrationError, message: "The screenshots role is gone, with its runs and which rule was whose."
  end
end

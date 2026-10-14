defmodule Rail.Repo.Migrations.AddScreensRoles do
  use Ecto.Migration

  # The screenshots agent is a role of its own now, set up as each project's QA role is, since it drives the
  # app the same way. Its prompt is `.rail/prompts/screens.md`; this copy is only the fallback.
  def up do
    execute """
    INSERT INTO roles (id, project_id, cli, stage, name, description, icon_name, model, reasoning_effort,
                       system_prompt, max_concurrent, position, mcp_tools, reserved_cpus, inserted_at, updated_at)
    SELECT 'rol_screens_' || qa.project_id, qa.project_id, qa.cli, 'screens', 'Screenshots',
           'Photographs every screen state a round''s change affects', 'pi-eye', qa.model, qa.reasoning_effort,
           'You photograph every screen state the change affects.', qa.max_concurrent, qa.position, qa.mcp_tools,
           qa.reserved_cpus, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
    FROM roles qa
    WHERE qa.stage = 'qa'
      AND NOT EXISTS (SELECT 1 FROM roles s WHERE s.project_id = qa.project_id AND s.stage = 'screens')
    """
  end

  def down do
    execute "DELETE FROM roles WHERE stage = 'screens'"
  end
end

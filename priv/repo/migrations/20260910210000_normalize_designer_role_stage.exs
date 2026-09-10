defmodule Rail.Repo.Migrations.NormalizeDesignerRoleStage do
  @moduledoc """
  Roles used to name the design stage `designer` while tasks named it `design`,
  so every lookup that crossed the two had to translate. This collapses roles
  onto `design`, the name the pipeline already uses.

  A project holding both a `designer` and a `design` role cannot have both
  promoted — the partial unique index on (project_id, stage) forbids it — so the
  leftover `designer` row is unbound from its stage rather than deleted. Its
  configuration survives and an admin can rebind or remove it.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE roles r
       SET stage = 'design'
     WHERE r.stage = 'designer'
       AND NOT EXISTS (
         SELECT 1 FROM roles d
          WHERE d.project_id = r.project_id
            AND d.stage = 'design'
       )
    """)

    execute("UPDATE roles SET stage = NULL WHERE stage = 'designer'")
  end

  def down do
    execute("UPDATE roles SET stage = 'designer' WHERE stage = 'design'")
  end
end

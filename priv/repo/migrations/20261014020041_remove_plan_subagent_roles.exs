defmodule Rail.Repo.Migrations.RemovePlanSubagentRoles do
  use Ecto.Migration

  # Plan writes the ticket, the design and the plan itself, so the three roles it led are gone, and the rules
  # people set for them are Plan's.
  def up do
    execute "DELETE FROM roles WHERE stage IN ('product', 'design', 'architect')"

    execute """
    UPDATE learnings
    SET roles = ARRAY(
      SELECT DISTINCT CASE WHEN role IN ('product', 'design', 'architect') THEN 'plan' ELSE role END
      FROM unnest(roles) AS role
    )
    WHERE roles && ARRAY['product', 'design', 'architect']
    """
  end

  def down do
    raise Ecto.MigrationError, message: "The product, design and architect roles are gone, with which rule was whose."
  end
end

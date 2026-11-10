defmodule Rail.Repo.Migrations.AssignIssueNumbers do
  @moduledoc false
  use Ecto.Migration

  # A trigger, since Postgres is the one place every insert of a Rail-tracked issue passes through. The advisory lock
  # is keyed on the issues table and the project, so it never shares a key with Oban's unique-job locks.
  def change do
    execute(
      """
      CREATE FUNCTION assign_issue_number() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock('issues'::regclass::int, hashtext(NEW.project_id));
        SELECT coalesce(max(number), 0) + 1 INTO NEW.number FROM issues WHERE project_id = NEW.project_id;
        SELECT key || '-' || NEW.number INTO NEW.identifier FROM projects WHERE id = NEW.project_id;
        NEW.branch_name := trim(both '-' from lower(
          NEW.identifier || '-' ||
          trim(both '-' from left(regexp_replace(lower(NEW.title), '[^a-z0-9]+', '-', 'g'), 40))
        ));
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION assign_issue_number()"
    )

    execute(
      """
      CREATE TRIGGER assign_issue_number BEFORE INSERT ON issues
      FOR EACH ROW WHEN (NEW.tracker = 'local' AND NEW.number IS NULL)
      EXECUTE FUNCTION assign_issue_number()
      """,
      "DROP TRIGGER assign_issue_number ON issues"
    )
  end
end

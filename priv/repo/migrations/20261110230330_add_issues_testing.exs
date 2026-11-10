defmodule Rail.Repo.Migrations.AddIssuesTesting do
  @moduledoc false
  use Ecto.Migration

  # A trigger, since the Linear and GitHub syncs write issues with `insert_all`, round every changeset. No row is
  # touched here, so a ticket already in Done never joins the testing queue.
  def change do
    alter table(:issues) do
      add :testing_state, :text
      add :testing_notes, :text
    end

    execute(
      """
      CREATE FUNCTION track_issue_testing() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.state = 'done' AND OLD.state IS DISTINCT FROM 'done' THEN
          NEW.testing_state := 'waiting';
          NEW.testing_notes := NULL;
        ELSIF OLD.state = 'done' AND NEW.state IS DISTINCT FROM 'done'
              AND NEW.testing_state IN ('waiting', 'testing') THEN
          NEW.testing_state := NULL;
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION track_issue_testing()"
    )

    execute(
      """
      CREATE TRIGGER track_issue_testing BEFORE UPDATE OF state ON issues
      FOR EACH ROW EXECUTE FUNCTION track_issue_testing()
      """,
      "DROP TRIGGER track_issue_testing ON issues"
    )
  end
end

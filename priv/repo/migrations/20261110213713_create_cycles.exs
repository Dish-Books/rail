defmodule Rail.Repo.Migrations.CreateCycles do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "DROP EXTENSION IF EXISTS btree_gist")

    create table(:cycles) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false

      timestamps()
    end

    create unique_index(:cycles, [:project_id, :number])
    create constraint(:cycles, :cycles_ends_after_start, check: "ends_on >= starts_on")

    create constraint(:cycles, :cycles_no_overlap,
             exclude: ~s|gist (project_id WITH =, daterange(starts_on, ends_on, '[]') WITH &&)|
           )

    # Numbered as `assign_issue_number` numbers issues, under a lock keyed on this table and the project.
    execute(
      """
      CREATE FUNCTION assign_cycle_number() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock('cycles'::regclass::int, hashtext(NEW.project_id));
        SELECT coalesce(max(number), 0) + 1 INTO NEW.number FROM cycles WHERE project_id = NEW.project_id;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION assign_cycle_number()"
    )

    execute(
      """
      CREATE TRIGGER assign_cycle_number BEFORE INSERT ON cycles
      FOR EACH ROW WHEN (NEW.number IS NULL) EXECUTE FUNCTION assign_cycle_number()
      """,
      "DROP TRIGGER assign_cycle_number ON cycles"
    )

    create table(:cycle_days) do
      add :cycle_id, references(:cycles, on_delete: :delete_all), null: false
      add :day, :date, null: false
      add :scope, :integer, null: false
      add :started, :integer, null: false
      add :completed, :integer, null: false
    end

    create unique_index(:cycle_days, [:cycle_id, :day])

    create table(:closed_cycle_issues) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :cycle_id, references(:cycles, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :state, :text, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:closed_cycle_issues, [:cycle_id, :issue_id])
    create index(:closed_cycle_issues, [:issue_id])
  end
end

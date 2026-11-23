defmodule Rail.Repo.Migrations.ReplaceExternalIssueColumns do
  @moduledoc false
  use Ecto.Migration

  # Issues point at their cycle and parent by Rail's own ids now. The tracker's ids, its status name and its updated_at
  # went with Linear and GitHub Issues.
  def up do
    alter table(:issues) do
      add :cycle_id, references(:cycles, on_delete: :nilify_all)
      add :parent_id, references(:issues, on_delete: :nilify_all)
    end

    execute "UPDATE issues SET cycle_id = cycle_external_id WHERE cycle_external_id IN (SELECT id FROM cycles)"

    execute """
    UPDATE issues i SET parent_id = p.id
    FROM issues p
    WHERE i.parent_external_id IS NOT NULL AND p.external_id = i.parent_external_id
    """

    create index(:issues, [:project_id, :cycle_id])
    create index(:issues, [:parent_id])

    alter table(:issues) do
      remove :external_id
      remove :parent_external_id
      remove :cycle_external_id
      remove :external_updated_at
      remove :state_name
    end

    alter table(:issue_comments) do
      remove :external_id
    end
  end

  # The tracker's ids come back drawn afresh, and its status names and updated_at empty.
  def down do
    alter table(:issue_comments) do
      add :external_id, :text
    end

    execute "UPDATE issue_comments SET external_id = gen_random_uuid()::text"
    execute "ALTER TABLE issue_comments ALTER COLUMN external_id SET NOT NULL"
    create unique_index(:issue_comments, [:external_id])

    alter table(:issues) do
      add :external_id, :text
      add :parent_external_id, :text
      add :cycle_external_id, :text
      add :external_updated_at, :utc_datetime_usec
      add :state_name, :text
    end

    execute "UPDATE issues SET external_id = gen_random_uuid()::text, cycle_external_id = cycle_id"
    execute "UPDATE issues i SET parent_external_id = p.external_id FROM issues p WHERE p.id = i.parent_id"
    execute "ALTER TABLE issues ALTER COLUMN external_id SET NOT NULL"
    create unique_index(:issues, [:external_id])
    create index(:issues, [:parent_external_id])
    create index(:issues, [:project_id, :cycle_external_id])
    create index(:issues, [:project_id, :external_updated_at])

    alter table(:issues) do
      remove :cycle_id
      remove :parent_id
    end
  end
end

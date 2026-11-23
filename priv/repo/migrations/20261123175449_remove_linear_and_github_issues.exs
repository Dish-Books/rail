defmodule Rail.Repo.Migrations.RemoveLinearAndGithubIssues do
  @moduledoc false
  use Ecto.Migration

  @workers [
    "Rail.Issues.Workers.LinearSync",
    "Rail.Issues.Workers.GithubSync",
    "Rail.Issues.Workers.EnsureGithubLabels",
    "Rail.Issues.Workers.MoveToLocalTracker",
    "Rail.Issues.Workers.CopyLinearFile"
  ]

  # Every project's issues are Rail's own, so the trigger names every issue that arrives unnamed, and no two issues of a
  # project share a number. A job queued for a worker that is gone would find no module.
  def up do
    execute "DROP TRIGGER assign_issue_number ON issues"

    execute """
    CREATE TRIGGER assign_issue_number BEFORE INSERT ON issues
    FOR EACH ROW WHEN (NEW.number IS NULL AND NEW.identifier IS NULL)
    EXECUTE FUNCTION assign_issue_number()
    """

    drop index(:issues, [:project_id, :number])
    create unique_index(:issues, [:project_id, :number])

    workers = Enum.map_join(@workers, ", ", &"'#{&1}'")
    execute "DELETE FROM oban_jobs WHERE worker IN (#{workers}) AND state NOT IN ('completed', 'discarded', 'cancelled')"

    alter table(:issues) do
      remove :tracker
    end

    alter table(:projects) do
      remove :tracker
      remove :linear_team_id
      remove :linear_state_ids
      remove :linear_workspace_id
    end

    alter table(:users) do
      remove :linear_user_id
      remove :linear_name
      remove :linear_access_token
      remove :linear_refresh_token
      remove :linear_token_expires_at
    end

    drop table(:linear_file_copies)
    drop table(:linear_workspaces)
  end

  # The columns and tables come back empty: what they held is gone.
  def down do
    create table(:linear_workspaces) do
      add :name, :text, null: false
      add :external_id, :text, null: false
      add :token, :binary, null: false
      add :webhook_secret, :binary, null: false
      timestamps()
    end

    create unique_index(:linear_workspaces, [:external_id])

    create table(:linear_file_copies) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :issue_external_id, :text, null: false
      add :issue_id, :text, null: false
      add :identifier, :text
      add :url, :text, null: false
      add :state, :text, null: false, default: "pending"
      add :copied_url, :text
      add :error, :text
      timestamps()
    end

    create unique_index(:linear_file_copies, [:project_id, :issue_external_id, :url])

    alter table(:users) do
      add :linear_user_id, :text
      add :linear_name, :text
      add :linear_access_token, :binary
      add :linear_refresh_token, :binary
      add :linear_token_expires_at, :utc_datetime_usec
    end

    alter table(:projects) do
      add :tracker, :text, null: false, default: "local"
      add :linear_team_id, :text
      add :linear_state_ids, :map, default: %{}, null: false
      add :linear_workspace_id, references(:linear_workspaces, type: :text, on_delete: :nilify_all)
    end

    create index(:projects, [:linear_workspace_id])

    alter table(:issues) do
      add :tracker, :text, null: false, default: "local"
    end

    drop index(:issues, [:project_id, :number])
    create unique_index(:issues, [:project_id, :number], where: "tracker = 'local'")

    execute "DROP TRIGGER assign_issue_number ON issues"

    execute """
    CREATE TRIGGER assign_issue_number BEFORE INSERT ON issues
    FOR EACH ROW WHEN (NEW.tracker = 'local' AND NEW.number IS NULL)
    EXECUTE FUNCTION assign_issue_number()
    """
  end
end

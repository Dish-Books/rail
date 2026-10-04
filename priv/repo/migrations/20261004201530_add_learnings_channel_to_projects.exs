defmodule Rail.Repo.Migrations.AddLearningsChannelToProjects do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :learnings_slack_workspace_id, references(:slack_workspaces)
      add :learnings_channel_external_id, :text
    end

    # Every project keeps posting its digest where it does today: its oldest triage channel not marked external.
    execute """
    UPDATE projects SET
      learnings_slack_workspace_id = oldest.slack_workspace_id,
      learnings_channel_external_id = oldest.external_id
    FROM (
      SELECT DISTINCT ON (project_id) project_id, slack_workspace_id, external_id
      FROM slack_channels
      WHERE NOT external
      ORDER BY project_id, inserted_at, id
    ) AS oldest
    WHERE oldest.project_id = projects.id
    """
  end

  def down do
    alter table(:projects) do
      remove :learnings_channel_external_id
      remove :learnings_slack_workspace_id
    end
  end
end

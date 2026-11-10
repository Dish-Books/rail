defmodule Rail.Repo.Migrations.CreateIssueRelationsAndLinks do
  use Ecto.Migration

  def change do
    create table(:issue_relations) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :blocker_issue_id, references(:issues, on_delete: :delete_all), null: false
      add :blocked_issue_id, references(:issues, on_delete: :delete_all), null: false

      timestamps()
    end

    # One relation per pair whichever way it points, so two tabs adding opposite directions write one row.
    create unique_index(
             :issue_relations,
             ["least(blocker_issue_id, blocked_issue_id)", "greatest(blocker_issue_id, blocked_issue_id)"],
             name: :issue_relations_pair_index
           )

    create index(:issue_relations, [:project_id, :blocker_issue_id])
    create index(:issue_relations, [:project_id, :blocked_issue_id])
    create constraint(:issue_relations, :issue_relations_distinct, check: "blocker_issue_id <> blocked_issue_id")

    create table(:issue_links) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :title, :text, null: false

      timestamps()
    end

    create unique_index(:issue_links, [:issue_id, :url])
  end
end

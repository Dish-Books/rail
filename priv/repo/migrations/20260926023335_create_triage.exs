defmodule Rail.Repo.Migrations.CreateTriage do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:slack_workspaces) do
      add :name, :text, null: false
      add :external_id, :text, null: false
      add :token, :binary, null: false
      add :app_token, :binary
      add :bot_id, :text
      add :bot_user_id, :text

      timestamps()
    end

    create unique_index(:slack_workspaces, [:external_id])

    create table(:slack_channels) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :slack_workspace_id, references(:slack_workspaces, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :name, :text, null: false
      add :triage_bot_messages, :boolean, default: false, null: false

      timestamps()
    end

    # One channel routes to one project.
    create unique_index(:slack_channels, [:external_id])
    create index(:slack_channels, [:project_id])
    create index(:slack_channels, [:slack_workspace_id])

    create table(:triage_threads) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :slack_channel_id, references(:slack_channels, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :title, :text
      add :permalink, :text
      add :status, :text, default: "triaging", null: false
      add :no_response_reason, :text
      add :error, :text
      # Held while a pass runs; a stale one is taken over.
      add :triage_started_at, :utc_datetime_usec
      add :mcp_token_hash, :binary
      add :forced, :boolean, default: false, null: false
      add :dismissed_by_id, references(:users, on_delete: :nilify_all)
      add :dismissed_at, :utc_datetime_usec
      add :last_message_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:triage_threads, [:slack_channel_id, :external_id])
    create index(:triage_threads, [:project_id, :status])
    create index(:triage_threads, [:mcp_token_hash])

    create table(:triage_messages) do
      add :thread_id, references(:triage_threads, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :author_external_id, :text
      add :author_name, :text
      add :from_bot, :boolean, default: false, null: false
      add :text, :text, null: false, default: ""
      add :posted_at, :utc_datetime_usec, null: false
      add :sent_by_user_id, references(:users, on_delete: :nilify_all)
      add :item_links, :jsonb, default: "[]", null: false
      add :no_response_reason, :text
      add :triaged_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:triage_messages, [:thread_id, :external_id])

    create table(:triage_items) do
      add :thread_id, references(:triage_threads, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :position, :integer, null: false
      add :kind, :text, null: false
      add :title, :text, null: false
      add :verdict, :text, null: false
      add :previous_verdict, :text
      add :summary, :text
      add :evidence, :jsonb, default: "[]", null: false
      add :assumptions, :jsonb, default: "[]", null: false
      add :existing_issue_id, references(:issues, on_delete: :nilify_all)
      add :issue_note, :text
      add :issue_title, :text
      add :issue_description, :text
      add :issue_priority, :text
      add :reply_text, :text
      add :issue_edited_by_id, references(:users, on_delete: :nilify_all)
      add :reply_edited_by_id, references(:users, on_delete: :nilify_all)
      add :created_issue_id, references(:issues, on_delete: :nilify_all)
      add :issue_created_by_id, references(:users, on_delete: :nilify_all)
      add :reply_posted_at, :utc_datetime_usec
      add :reply_posted_by_id, references(:users, on_delete: :nilify_all)
      add :retriaging, :boolean, default: false, null: false
      add :retriaged_at, :utc_datetime_usec
      add :error, :text

      timestamps()
    end

    create unique_index(:triage_items, [:thread_id, :key])

    create table(:triage_corrections) do
      add :thread_id, references(:triage_threads, on_delete: :delete_all), null: false
      add :item_id, references(:triage_items, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :text, :text, null: false
      add :assumption, :text

      timestamps()
    end

    create index(:triage_corrections, [:thread_id])

    alter table(:users) do
      add :slack_user_id, :text
      add :slack_team_id, :text
      add :slack_name, :text
      add :slack_access_token, :binary
    end

    # A deleted user leaves triage running without their MCP accounts rather than blocking the delete.
    alter table(:projects) do
      add :triage_user_id, references(:users, on_delete: :nilify_all)
    end
  end
end

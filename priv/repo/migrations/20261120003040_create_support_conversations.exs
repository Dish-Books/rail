defmodule Rail.Repo.Migrations.CreateSupportConversations do
  use Ecto.Migration

  def change do
    create table(:intercom_workspaces) do
      add :name, :text, null: false
      add :external_id, :text, null: false
      add :access_token, :binary, null: false
      add :client_id, :text, null: false
      add :client_secret, :binary, null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:intercom_workspaces, [:external_id])

    create table(:support_conversations) do
      add :external_id, :text, null: false
      add :title, :text
      add :customer_name, :text
      add :customer_email, :text
      add :status, :text, null: false, default: "waiting"
      add :done_at, :utc_datetime_usec
      add :done_by_id, references(:users, on_delete: :nilify_all)
      add :last_message_at, :utc_datetime_usec
      add :intercom_updated_at, :utc_datetime_usec, null: false
      add :reply_text, :text
      add :drafting_since, :utc_datetime_usec
      add :agent_started_at, :utc_datetime_usec
      add :mcp_token_hash, :binary
      add :agent_error, :text
      add :drafted_at, :utc_datetime_usec
      add :reply_posted_at, :utc_datetime_usec
      add :reply_posted_by_id, references(:users, on_delete: :nilify_all)
      add :send_started_at, :utc_datetime_usec
      add :send_error, :text
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :intercom_workspace_id, references(:intercom_workspaces, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:support_conversations, [:intercom_workspace_id, :external_id])
    create index(:support_conversations, [:project_id, :status, :last_message_at])
    create index(:support_conversations, [:mcp_token_hash])

    create table(:support_messages) do
      add :external_id, :text, null: false
      add :kind, :text, null: false
      add :author_name, :text
      add :text, :text, null: false, default: ""
      add :posted_at, :utc_datetime_usec, null: false
      add :attachments, :jsonb, null: false, default: "[]"
      add :conversation_id, references(:support_conversations, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:support_messages, [:conversation_id, :external_id])

    create table(:support_items) do
      add :key, :text, null: false
      add :position, :integer, null: false
      add :kind, :text, null: false
      add :title, :text, null: false
      add :verdict, :text, null: false
      add :summary, :text
      add :evidence, :jsonb, null: false, default: "[]"
      add :assumptions, :jsonb, null: false, default: "[]"
      add :issue_title, :text
      add :issue_description, :text
      add :issue_priority, :text
      add :issue_estimate, :integer
      add :forwarded_at, :utc_datetime_usec
      add :existing_issue_id, references(:issues, on_delete: :nilify_all)
      add :conversation_id, references(:support_conversations, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:support_items, [:conversation_id, :key])

    create table(:support_chat_messages) do
      add :author, :text, null: false
      add :text, :text, null: false
      add :changes, :text
      add :user_id, references(:users, on_delete: :nilify_all)
      add :conversation_id, references(:support_conversations, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:support_chat_messages, [:conversation_id, :inserted_at])

    alter table(:users) do
      add :intercom_admin_id, :text
      add :intercom_app_id, :text
      add :intercom_name, :text
      add :intercom_access_token, :binary
    end

    alter table(:triage_threads) do
      modify :slack_channel_id, :text, null: true, from: {:text, null: false}
      add :support_conversation_id, references(:support_conversations)
      add :forwarded_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end

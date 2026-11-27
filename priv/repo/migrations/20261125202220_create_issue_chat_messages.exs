defmodule Rail.Repo.Migrations.CreateIssueChatMessages do
  use Ecto.Migration

  def change do
    create table(:issue_chat_messages) do
      add :author, :text, null: false
      add :text, :text, null: false
      add :changes, :text
      add :user_id, references(:users, on_delete: :nilify_all)
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:issue_chat_messages, [:issue_id, :inserted_at])

    alter table(:issues) do
      add :chat_requested_at, :utc_datetime_usec
      add :chat_started_at, :utc_datetime_usec
      add :chat_token_hash, :binary
      add :chat_error, :text
    end
  end
end

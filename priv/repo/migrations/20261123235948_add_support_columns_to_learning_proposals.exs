defmodule Rail.Repo.Migrations.AddSupportColumnsToLearningProposals do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:learning_proposals) do
      add :support_conversation_id, references(:support_conversations, on_delete: :delete_all)
      add :support_key, :text
      add :support_chat_message_id, references(:support_chat_messages, on_delete: :delete_all)
    end

    create unique_index(:learning_proposals, [:support_conversation_id, :support_key], concurrently: true)
    create index(:learning_proposals, [:support_chat_message_id], concurrently: true)
  end
end

defmodule Rail.Repo.Migrations.AddSupportConversationToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      # The Intercom conversation a ticket was created from, which agents read from Support rather than a copy.
      add :support_conversation_id, references(:support_conversations)
    end
  end
end

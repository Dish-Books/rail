defmodule Rail.Repo.Migrations.AddEmbeddingToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :embedding, :vector, size: 3072
      add :embedding_digest, :text
    end
  end
end

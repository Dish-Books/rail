defmodule Rail.Repo.Migrations.AddReviewFindingSuggestion do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:review_findings) do
      add :suggestion, :text
    end
  end
end

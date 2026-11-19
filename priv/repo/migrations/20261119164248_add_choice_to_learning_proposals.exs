defmodule Rail.Repo.Migrations.AddChoiceToLearningProposals do
  use Ecto.Migration

  def change do
    alter table(:learning_proposals) do
      # A task proposal's Approve or Reject so far, still pending until its task merges.
      add :choice, :text
    end
  end
end

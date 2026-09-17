defmodule Rail.Repo.Migrations.ReviewFindingDecisionIsTheHumans do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:review_findings) do
      modify :decision, :text, null: true
    end

    # Every decision on record was seeded from the reviewer's recommendation
    # rather than made, and there is no way to tell those apart now. Clearing
    # them asks the human once rather than showing them a ruling they never gave.
    execute "UPDATE review_findings SET decision = NULL WHERE status <> 'fixed'"
  end

  def down do
    execute "UPDATE review_findings SET decision = recommendation WHERE decision IS NULL"

    alter table(:review_findings) do
      modify :decision, :text, null: false
    end
  end
end

defmodule Rail.Repo.Migrations.DropQuestionsContextSummary do
  use Ecto.Migration

  # Its only value was "Asked during: <task title>", which names the task the page already shows.
  def change do
    alter table(:questions) do
      remove :context_summary, :text
    end
  end
end

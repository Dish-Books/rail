defmodule Rail.Repo.Migrations.AddIssueToFindings do
  use Ecto.Migration

  def change do
    alter table(:findings) do
      # A deleted issue leaves the finding ruled New issue and unfiled, so the next Send files it again.
      add :issue_id, references(:issues, on_delete: :nilify_all)
    end
  end
end

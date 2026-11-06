defmodule Rail.Repo.Migrations.AddPullRequestToIssues do
  @moduledoc false
  use Ecto.Migration

  # The pull request an issue's work was opened as outside Rail, once found, so it is not looked up again.
  def change do
    alter table(:issues) do
      add :pr_number, :integer
      add :pr_url, :text
      add :pr_title, :text
    end
  end
end

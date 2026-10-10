defmodule Rail.Repo.Migrations.AddCommitToDiffComments do
  use Ecto.Migration

  # A comment written in one commit's view keeps that commit, since its line numbers are that commit's.
  def change do
    alter table(:diff_comments) do
      add :commit, :text
    end
  end
end

defmodule Rail.Repo.Migrations.CreateIssueComments do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:issue_comments) do
      add :issue_id, references(:issues, type: :text, on_delete: :delete_all), null: false
      add :parent_id, references(:issue_comments, type: :text, on_delete: :delete_all)
      add :author_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :external_id, :text, null: false
      add :body, :text, default: "", null: false
      add :author_name, :text
      add :author_avatar_url, :text

      timestamps()
    end

    create unique_index(:issue_comments, [:external_id])
    create index(:issue_comments, [:issue_id])
    create index(:issue_comments, [:parent_id])
    create index(:issue_comments, [:author_user_id])
  end
end

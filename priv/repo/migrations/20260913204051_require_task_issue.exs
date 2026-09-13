defmodule Rail.Repo.Migrations.RequireTaskIssue do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      modify :issue_id, references(:issues, type: :text, on_delete: :delete_all),
        null: false,
        from: {references(:issues, type: :text, on_delete: :nilify_all), null: true}
    end
  end
end

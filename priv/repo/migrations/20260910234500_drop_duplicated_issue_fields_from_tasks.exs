defmodule Rail.Repo.Migrations.DropDuplicatedIssueFieldsFromTasks do
  @moduledoc """
  A task links to its issue; it no longer carries its own copy of the issue's
  title, description and owner.
  """

  use Ecto.Migration

  def change do
    alter table(:tasks) do
      remove :title, :text, null: false
      remove :description, :text
      remove :owner_user_id, references(:users, type: :text, on_delete: :nilify_all)
    end
  end
end

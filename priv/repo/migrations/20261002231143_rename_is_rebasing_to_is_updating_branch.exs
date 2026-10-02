defmodule Rail.Repo.Migrations.RenameIsRebasingToIsUpdatingBranch do
  use Ecto.Migration

  def change do
    rename table(:tasks), :is_rebasing, to: :is_updating_branch
  end
end

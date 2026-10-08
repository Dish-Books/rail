defmodule Rail.Repo.Migrations.AddAccountSeedCommandToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :account_seed_command, :text
    end
  end
end

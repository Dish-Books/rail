defmodule Rail.Repo.Migrations.CreateInvites do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:invites) do
      add :email, :citext, null: false
      add :admin, :boolean, default: false, null: false
      add :accepted_at, :utc_datetime_usec
      add :invited_by_id, references(:users, type: :text, on_delete: :nilify_all)
      add :accepted_user_id, references(:users, type: :text, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:invites, [:email])
    create index(:invites, [:invited_by_id])
    create index(:invites, [:accepted_user_id])
  end
end

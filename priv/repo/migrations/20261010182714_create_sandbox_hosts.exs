defmodule Rail.Repo.Migrations.CreateSandboxHosts do
  use Ecto.Migration

  def change do
    create table(:sandbox_hosts) do
      add :name, :text, null: false
      add :ssh_address, :text, null: false
      add :private_key, :binary, null: false
      add :public_key, :text, null: false
      add :host_key_fingerprint, :text
      add :removed_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:sandbox_hosts, [:name], where: "removed_at IS NULL", name: :sandbox_hosts_live_name_index)
  end
end

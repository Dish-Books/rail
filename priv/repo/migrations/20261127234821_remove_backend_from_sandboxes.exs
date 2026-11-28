defmodule Rail.Repo.Migrations.RemoveBackendFromSandboxes do
  use Ecto.Migration

  # A sandbox no longer mounts an account's login: Claude reaches its account through Rail's proxy.
  def change do
    alter table(:sandboxes) do
      remove :backend_id, references(:backends, on_delete: :nilify_all)
    end
  end
end

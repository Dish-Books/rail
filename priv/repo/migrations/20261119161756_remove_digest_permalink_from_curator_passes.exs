defmodule Rail.Repo.Migrations.RemoveDigestPermalinkFromCuratorPasses do
  use Ecto.Migration

  def change do
    alter table(:curator_passes) do
      remove :digest_permalink, :text
    end
  end
end

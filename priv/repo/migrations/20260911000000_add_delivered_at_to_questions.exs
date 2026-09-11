defmodule Rail.Repo.Migrations.AddDeliveredAtToQuestions do
  use Ecto.Migration

  def change do
    alter table(:questions) do
      add :delivered_at, :utc_datetime_usec
    end

    create index(:questions, [:task_id, :status])
  end
end

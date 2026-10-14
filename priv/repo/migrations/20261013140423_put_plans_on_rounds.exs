defmodule Rail.Repo.Migrations.PutPlansOnRounds do
  use Ecto.Migration

  # The ticket and the design a plan is written for sit beside it on the round, and an approved plan is round 1's.
  def up do
    alter table(:rounds) do
      add :ticket, :map
      add :design, :map
    end

    flush()

    %{rows: plans} = repo().query!("SELECT task_id, content, captured_at FROM implementation_plans")

    for [task_id, content, captured_at] <- plans do
      repo().query!(
        """
        INSERT INTO rounds (id, task_id, number, plan, plan_version, plan_saved_at, approved_at, inserted_at, updated_at)
        VALUES ($1, $2, 1, $3, 1, $4, $4, $4, $4)
        """,
        [UXID.generate!(prefix: "rnd"), task_id, content, captured_at]
      )
    end

    drop table(:implementation_plans)
  end

  def down do
    create table(:implementation_plans) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create unique_index(:implementation_plans, [:task_id])

    alter table(:rounds) do
      remove :ticket
      remove :design
    end
  end
end

defmodule Rail.Repo.Migrations.QuestionsBelongToTheRunThatAsked do
  use Ecto.Migration

  # A question was pointed at a role and the run rebuilt from `(task_id, role_id)`
  # on the way back. That worked only because a task holds one run per role -- an
  # invariant with no index behind it -- and it sent a re-asked prompt's answer to
  # whichever role first filed it. The run that asked is the fact; store it.
  #
  # `tasks.question_id` went with it: every writer set it to the oldest pending
  # question, which the questions table already answers.
  def up do
    alter table(:questions) do
      add :run_id, references(:runs, type: :text, on_delete: :delete_all)
    end

    execute """
    UPDATE questions q
    SET run_id = r.id
    FROM runs r
    WHERE r.task_id = q.task_id
      AND r.role_id = q.role_id
    """

    # Anything left has no run to belong to and can no longer be answered.
    execute "DELETE FROM questions WHERE run_id IS NULL"

    execute "ALTER TABLE questions ALTER COLUMN run_id SET NOT NULL"
    create index(:questions, [:run_id])

    alter table(:questions) do
      remove :role_id
    end

    alter table(:tasks) do
      remove :question_id
    end
  end

  def down do
    alter table(:tasks) do
      add :question_id, :text
    end

    execute """
    UPDATE tasks t
    SET question_id = (
      SELECT q.id
      FROM questions q
      WHERE q.task_id = t.id AND q.status = 'pending'
      ORDER BY q.inserted_at ASC, q.id ASC
      LIMIT 1
    )
    WHERE t.stage_state = 'blocked'
    """

    alter table(:questions) do
      add :role_id, references(:roles, type: :text, on_delete: :nilify_all)
    end

    execute """
    UPDATE questions q
    SET role_id = r.role_id
    FROM runs r
    WHERE r.id = q.run_id
    """

    drop index(:questions, [:run_id])

    alter table(:questions) do
      remove :run_id
    end
  end
end

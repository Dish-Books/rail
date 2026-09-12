defmodule Rail.Repo.Migrations.RenameRunsToOsProcessesAndRoleRunsToRuns do
  use Ecto.Migration

  # "run" used to name the OS process and "role run" the execution it belonged to,
  # which reads backwards: the thing a user calls a run is the role run. This moves
  # the word down one level, giving task -> run -> os_process -> run_event.
  #
  # Order matters throughout: index and constraint names are schema-global, so the
  # old `runs` names have to be vacated before `role_runs` can claim them.

  def up do
    rename table(:runs), to: table(:os_processes)
    rename table(:role_runs), to: table(:runs)

    # os_processes still carries the index/constraint names it had as `runs`.
    execute "ALTER INDEX runs_pkey RENAME TO os_processes_pkey"
    execute "ALTER INDEX runs_node_status_index RENAME TO os_processes_node_status_index"
    execute "ALTER INDEX runs_role_run_id_index RENAME TO os_processes_run_id_index"
    execute "ALTER TABLE os_processes RENAME CONSTRAINT runs_role_run_id_fkey TO os_processes_run_id_fkey"

    # ...which frees them for the table that is now `runs`.
    execute "ALTER INDEX role_runs_pkey RENAME TO runs_pkey"
    execute "ALTER INDEX role_runs_task_id_role_id_index RENAME TO runs_task_id_role_id_index"
    execute "ALTER INDEX role_runs_conversation_id_index RENAME TO runs_conversation_id_index"

    rename table(:os_processes), :role_run_id, to: :run_id
    rename table(:run_events), :role_run_id, to: :run_id
    rename table(:qa_reports), :role_run_id, to: :run_id

    execute "ALTER INDEX run_events_role_run_id_seq_index RENAME TO run_events_run_id_seq_index"
    execute "ALTER TABLE run_events RENAME CONSTRAINT run_events_role_run_id_fkey TO run_events_run_id_fkey"
  end

  def down do
    execute "ALTER TABLE run_events RENAME CONSTRAINT run_events_run_id_fkey TO run_events_role_run_id_fkey"
    execute "ALTER INDEX run_events_run_id_seq_index RENAME TO run_events_role_run_id_seq_index"

    rename table(:qa_reports), :run_id, to: :role_run_id
    rename table(:run_events), :run_id, to: :role_run_id
    rename table(:os_processes), :run_id, to: :role_run_id

    execute "ALTER INDEX runs_conversation_id_index RENAME TO role_runs_conversation_id_index"
    execute "ALTER INDEX runs_task_id_role_id_index RENAME TO role_runs_task_id_role_id_index"
    execute "ALTER INDEX runs_pkey RENAME TO role_runs_pkey"

    execute "ALTER TABLE os_processes RENAME CONSTRAINT os_processes_run_id_fkey TO runs_role_run_id_fkey"
    execute "ALTER INDEX os_processes_run_id_index RENAME TO runs_role_run_id_index"
    execute "ALTER INDEX os_processes_node_status_index RENAME TO runs_node_status_index"
    execute "ALTER INDEX os_processes_pkey RENAME TO runs_pkey"

    rename table(:runs), to: table(:role_runs)
    rename table(:os_processes), to: table(:runs)
  end
end

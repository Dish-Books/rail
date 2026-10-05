defmodule Rail.Repo.Migrations.CombinePlanStage do
  use Ecto.Migration

  # Product, design and architect become one Plan step. Their roles stay, as Plan's
  # subagents, and each project gets a Plan role on its architect's backend and
  # model, allowed every MCP tool any of the three was.
  #
  # A task at any of the three moves to Plan with a Plan run copied from its latest
  # run there, so the conversation carries on where the backend can resume it. A run
  # caught mid-turn is settled as stopped; its tokens stay on the old run.
  def up do
    %{rows: architects} =
      repo().query!("""
      SELECT a.project_id, a.backend_id, a.model, a.reasoning_effort, a.max_concurrent, a.position,
             a.reserved_cpus, a.reserved_memory_gb,
             ARRAY(
               SELECT DISTINCT tool FROM roles r, unnest(r.mcp_tools) AS tool
               WHERE r.project_id = a.project_id AND r.stage IN ('product', 'design', 'architect')
               ORDER BY tool
             )
      FROM roles a
      WHERE a.stage = 'architect'
        AND NOT EXISTS (SELECT 1 FROM roles p WHERE p.project_id = a.project_id AND p.stage = 'plan')
      """)

    for [project_id, backend_id, model, effort, max_concurrent, position, cpus, memory_gb, mcp_tools] <- architects do
      repo().query!(
        """
        INSERT INTO roles (id, project_id, backend_id, stage, name, description, icon_name, model, reasoning_effort,
                           system_prompt, max_concurrent, position, mcp_tools, reserved_cpus, reserved_memory_gb,
                           inserted_at, updated_at)
        VALUES ($1, $2, $3, 'plan', 'Plan', $4, 'pi-compass-tool', $5, $6, $7, $8, $9, $10, $11, $12,
                now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          UXID.generate!(prefix: "rol"),
          project_id,
          backend_id,
          "Leads Product, Designer and Architect to the ticket, the design and the plan",
          model,
          effort,
          "You lead Rail's Plan step for this project.",
          max_concurrent,
          position,
          mcp_tools,
          cpus,
          memory_gb
        ]
      )
    end

    %{rows: latest} =
      repo().query!("""
      SELECT DISTINCT ON (t.id) t.id, r.id, r.status, r.stage_outcome, r.error, r.exit_code, r.started_at,
             r.completed_at, CASE WHEN old_role.backend_id = plan.backend_id THEN r.conversation_id END, plan.id
      FROM tasks t
      JOIN runs r ON r.task_id = t.id
      JOIN roles old_role ON old_role.id = r.role_id AND old_role.stage IN ('product', 'design', 'architect')
      JOIN roles plan ON plan.project_id = t.project_id AND plan.stage = 'plan'
      WHERE t.stage IN ('product', 'design', 'architect')
      ORDER BY t.id, r.started_at DESC, r.inserted_at DESC
      """)

    for [task_id, old_run_id, status, outcome, error, exit_code, started_at, completed_at, conversation_id, role_id] <-
          latest do
      run_id = UXID.generate!(prefix: "run")
      status = if status in ["starting", "running", "waiting_for_resources"], do: "finished", else: status

      repo().query!(
        """
        INSERT INTO runs (id, task_id, role_id, conversation_id, status, stage_outcome, error, exit_code, started_at,
                          completed_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [run_id, task_id, role_id, conversation_id, status, outcome, error, exit_code, started_at, completed_at]
      )

      repo().query!("UPDATE questions SET run_id = $1 WHERE run_id = $2 AND delivered_at IS NULL", [
        run_id,
        old_run_id
      ])
    end

    execute "UPDATE tasks SET stage = 'plan' WHERE stage IN ('product', 'design', 'architect')"

    alter table(:tasks) do
      modify :stage, :text, default: "plan", from: {:text, default: "product"}
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "The Plan stage cannot be split again: the tasks moved into it no longer say which stage they were at."
  end
end

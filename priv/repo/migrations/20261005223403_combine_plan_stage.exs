defmodule Rail.Repo.Migrations.CombinePlanStage do
  use Ecto.Migration

  # Product, design and architect become one Plan step, and every task is brought to
  # it here so no code has to know the old flow. Their roles stay, as Plan's
  # subagents, and each project gets a Plan role on its architect's CLI and
  # model, allowed every MCP tool any of the three was.
  #
  # Every task that ran any of the three gets one Plan run in their place, with no
  # conversation, and their runs and history go. A task still at one of the three
  # moves to Plan, stopped, for Retry to start; one past it has its Plan run done.
  # A run still going would outlive its row, so the deploy waits until none is.
  def up do
    %{rows: in_flight} =
      repo().query!("""
      SELECT DISTINCT r.task_id
      FROM runs r
      JOIN roles old_role ON old_role.id = r.role_id AND old_role.stage IN ('product', 'design', 'architect')
      WHERE r.status IN ('starting', 'running', 'waiting_for_resources')
      ORDER BY r.task_id
      """)

    if in_flight != [] do
      raise Ecto.MigrationError,
        message:
          "Stop the product, design and architect runs still going on these tasks before deploying: " <>
            Enum.map_join(in_flight, ", ", &hd/1)
    end

    insert_plan_roles()
    record_files()
    insert_plan_runs()

    repo().query!("""
    DELETE FROM runs USING roles
    WHERE roles.id = runs.role_id AND roles.stage IN ('product', 'design', 'architect')
    """)

    execute "UPDATE tasks SET stage = 'plan' WHERE stage IN ('product', 'design', 'architect')"

    alter table(:tasks) do
      modify :stage, :text, default: "plan", from: {:text, default: "product"}
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "The Plan stage cannot be split again: the runs it replaced are gone."
  end

  defp insert_plan_roles do
    %{rows: architects} =
      repo().query!("""
      SELECT a.project_id, a.cli, a.model, a.reasoning_effort, a.max_concurrent, a.position,
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

    for [project_id, cli, model, effort, max_concurrent, position, cpus, memory_gb, mcp_tools] <- architects do
      repo().query!(
        """
        INSERT INTO roles (id, project_id, cli, stage, name, description, icon_name, model, reasoning_effort,
                           system_prompt, max_concurrent, position, mcp_tools, reserved_cpus, reserved_memory_gb,
                           inserted_at, updated_at)
        VALUES ($1, $2, $3, 'plan', 'Plan', $4, 'pi-compass-tool', $5, $6, $7, $8, $9, $10, $11, $12,
                now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          UXID.generate!(prefix: "rol"),
          project_id,
          cli,
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
  end

  defp insert_plan_runs do
    %{rows: latest} =
      repo().query!("""
      SELECT DISTINCT ON (t.id) t.id, t.stage IN ('product', 'design', 'architect'), r.started_at, r.completed_at,
             plan.id
      FROM tasks t
      JOIN runs r ON r.task_id = t.id
      JOIN roles old_role ON old_role.id = r.role_id AND old_role.stage IN ('product', 'design', 'architect')
      JOIN roles plan ON plan.project_id = t.project_id AND plan.stage = 'plan'
      WHERE NOT EXISTS (SELECT 1 FROM runs p WHERE p.task_id = t.id AND p.role_id = plan.id)
      ORDER BY t.id, r.started_at DESC, r.inserted_at DESC
      """)

    for [task_id, at_plan?, started_at, completed_at, role_id] <- latest do
      repo().query!(
        """
        INSERT INTO runs (id, task_id, role_id, status, stage_outcome, started_at, completed_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'finished', $4, $5, $6, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          UXID.generate!(prefix: "run"),
          task_id,
          role_id,
          if(at_plan?, do: "in_progress", else: "done"),
          started_at,
          completed_at
        ]
      )
    end
  end

  # The files the Plan tab reads, written for every task whatever its stage, so an
  # old task reads exactly as one approved after this.
  defp record_files do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier,
             EXISTS (
               SELECT 1 FROM runs r JOIN roles ro ON ro.id = r.role_id
               WHERE r.task_id = tasks.id AND ro.stage = 'product'
             ),
             issues.title, issues.description, issues.priority, issues.estimate
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier, had_product? | issue] <- rows, File.dir?(scratch_path) do
      record_option(scratch_path, identifier)
      if not had_product?, do: record_ticket(scratch_path, identifier, issue)
    end
  end

  # Under the old flow the architect only started once the design was approved, so a
  # saved plan was written for the pick.
  defp record_option(scratch_path, identifier) do
    plans = Path.join(scratch_path, "plans")
    design = Path.join(scratch_path, "design")

    with true <- File.regular?(Path.join(plans, "#{identifier}.md")),
         {:ok, picked} <- File.read(Path.join(design, "picked")),
         key = String.trim(picked),
         {:ok, manifest} <- File.read(Path.join(design, "manifest.json")),
         {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(manifest),
         %{"title" => title} when is_binary(title) <- Enum.find(options, &match?(%{"key" => ^key}, &1)) do
      write(Path.join(plans, "#{identifier}.design.json"), Jason.encode!(%{key: key, title: String.trim(title)}))
    end
  end

  # A task that never had a product run was started straight at design or architect,
  # its issue being its ticket. The design section approving the design appended is
  # left off, since approving the plan appends it again.
  defp record_ticket(scratch_path, identifier, [title, description, priority, estimate]) do
    path = Path.join([scratch_path, "tickets", "#{identifier}.md"])

    if not File.regular?(path) do
      description = description || ""

      description =
        case :binary.matches(description, "\n\n## Design: ") do
          [] -> description
          matches -> binary_part(description, 0, matches |> List.last() |> elem(0))
        end

      fields =
        [title: String.trim(title || ""), priority: priority, estimate: estimate && Integer.to_string(estimate)]
        |> Enum.reject(fn {_field, value} -> value in [nil, ""] end)
        |> Enum.map_join("\n", fn {field, value} -> "#{field}: #{value}" end)

      File.mkdir_p!(Path.dirname(path))
      write(path, String.trim_trailing("---\n#{fields}\n---\n\n#{String.trim(description)}") <> "\n")
    end
  end

  defp write(path, content) do
    temporary = path <> ".rewrite"
    File.write!(temporary, content)
    File.rename!(temporary, path)
  end
end

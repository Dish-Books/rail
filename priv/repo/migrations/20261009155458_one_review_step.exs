defmodule Rail.Repo.Migrations.OneReviewStep do
  use Ecto.Migration

  # Review, QA and Demo become one Review step led by a Review lead, and every task is brought to it here so
  # no code has to know the old flow. Their roles stay, as the lead's subagents, and each project gets a lead
  # on its Review role's CLI and model, allowed every MCP tool any of the three was.
  #
  # Review and QA findings become one list in round 1, kept as they read today; the limits and the evidence
  # rule apply to new saves only. A run still going would outlive its row, so the deploy waits until none is.
  def up do
    %{rows: in_flight} =
      repo().query!("""
      SELECT DISTINCT r.task_id
      FROM runs r
      JOIN roles old_role ON old_role.id = r.role_id AND old_role.stage IN ('review', 'qa', 'demo')
      WHERE r.status IN ('starting', 'running', 'waiting_for_resources', 'waiting_for_usage')
      ORDER BY r.task_id
      """)

    if in_flight != [] do
      raise Ecto.MigrationError,
        message:
          "Stop the review, QA and demo runs still going on these tasks before deploying: " <>
            Enum.map_join(in_flight, ", ", &hd/1)
    end

    insert_lead_roles()
    findings_table()
    flush()

    fill_review_findings()
    copy_qa_findings()

    drop table(:qa_findings)
    flush()

    rewrite_files()
    insert_lead_runs()

    repo().query!("""
    DELETE FROM runs USING roles
    WHERE roles.id = runs.role_id AND roles.stage IN ('review', 'qa', 'demo')
    """)

    execute "UPDATE tasks SET stage = 'review' WHERE stage IN ('qa', 'demo')"

    alter table(:tasks) do
      remove :demo_skipped_at, :utc_datetime_usec
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "Review cannot be split into review, QA and demo again: the runs it replaced are gone."
  end

  defp insert_lead_roles do
    %{rows: reviewers} =
      repo().query!("""
      SELECT r.project_id, r.cli, r.model, r.reasoning_effort, r.max_concurrent, r.position,
             r.reserved_cpus, r.reserved_memory_gb,
             ARRAY(
               SELECT DISTINCT tool FROM roles o, unnest(o.mcp_tools) AS tool
               WHERE o.project_id = r.project_id AND o.stage IN ('review', 'qa', 'demo')
               ORDER BY tool
             )
      FROM roles r
      WHERE r.stage = 'review'
        AND NOT EXISTS (SELECT 1 FROM roles l WHERE l.project_id = r.project_id AND l.stage = 'review_lead')
      """)

    for [project_id, cli, model, effort, max_concurrent, position, cpus, memory_gb, mcp_tools] <- reviewers do
      repo().query!(
        """
        INSERT INTO roles (id, project_id, cli, stage, name, description, icon_name, model, reasoning_effort,
                           system_prompt, max_concurrent, position, mcp_tools, reserved_cpus, reserved_memory_gb,
                           inserted_at, updated_at)
        VALUES ($1, $2, $3, 'review_lead', 'Review lead', $4, 'pi-seal-check-fill', $5, $6, $7, $8, $9, $10, $11,
                $12, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          UXID.generate!(prefix: "rol"),
          project_id,
          cli,
          "Leads the code reviewer, QA explorers, engineer and demo recorder through Review",
          model,
          effort,
          "You lead Rail's Review step for this project.",
          max_concurrent,
          position,
          mcp_tools,
          cpus,
          memory_gb
        ]
      )
    end
  end

  defp findings_table do
    rename table(:review_findings), to: table(:findings)

    execute "ALTER TABLE findings RENAME CONSTRAINT review_findings_pkey TO findings_pkey"
    execute "ALTER TABLE findings RENAME CONSTRAINT review_findings_task_id_fkey TO findings_task_id_fkey"
    execute "ALTER TABLE findings RENAME CONSTRAINT review_findings_rule_id_fkey TO findings_rule_id_fkey"

    execute "ALTER TABLE findings RENAME CONSTRAINT review_findings_suppressed_by_id_fkey TO " <>
              "findings_suppressed_by_id_fkey"

    execute "ALTER TABLE findings RENAME CONSTRAINT review_findings_decided_by_id_fkey TO findings_decided_by_id_fkey"
    execute "ALTER INDEX review_findings_task_id_key_index RENAME TO findings_task_id_key_index"
    execute "ALTER INDEX review_findings_rule_id_index RENAME TO findings_rule_id_index"
    execute "ALTER INDEX review_findings_suppressed_by_id_index RENAME TO findings_suppressed_by_id_index"

    alter table(:findings) do
      add :kind, :text, null: false, default: "code"
      add :raised_by, :text, null: false, default: "code_reviewer"
      add :round, :integer, null: false, default: 1
      add :carried_round, :integer
      add :problem, :text
      add :end_line, :integer
      add :screen, :text
      add :steps, {:array, :text}, null: false, default: []
      add :check, :text
      add :fix, :text
      add :why, :text
      add :rule, :text
      add :raised_in, :text
      add :fixed_in, :text
      add :places, :jsonb, null: false, default: "[]"
      add :evidence, :jsonb, null: false, default: "[]"
      add :notes, :jsonb, null: false, default: "[]"
    end
  end

  # A finding that names a line is its own one place, so the list can show where it is.
  defp fill_review_findings do
    execute """
    UPDATE findings SET
      problem = detail,
      fix = suggestion,
      places = CASE WHEN file IS NULL THEN '[]'::jsonb
                    ELSE jsonb_build_array(jsonb_build_object('file', file, 'line', line, 'steps', '[]'::jsonb)) END,
      notes = #{notes()}
    """

    alter table(:findings) do
      remove :detail, :text
      remove :suggestion, :text
    end
  end

  # A QA key the reviewer already used on the task is renamed rather than lost.
  defp copy_qa_findings do
    execute """
    INSERT INTO findings (id, task_id, key, kind, raised_by, round, title, problem, screen, steps, "check", fix,
                          severity, recommendation, status, decision, decided_by_id, places, evidence, notes,
                          inserted_at, updated_at)
    SELECT q.id, q.task_id,
           CASE WHEN EXISTS (SELECT 1 FROM findings f WHERE f.task_id = q.task_id AND f.key = q.key)
                THEN q.key || '-qa' ELSE q.key END,
           'screen', 'explorer', 1, q.title,
           COALESCE(q.detail, concat_ws(' ', 'Expected: ' || q.expected || '.', 'Observed: ' || q.observed || '.')),
           q.screen,
           ARRAY(SELECT regexp_replace(trim(step), '^\\d+[.)]\\s*', '')
                 FROM unnest(regexp_split_to_array(COALESCE(q.steps, ''), E'\\n')) AS step
                 WHERE trim(step) <> ''),

           q."check", q.suggestion, q.severity, q.recommendation, q.status, q.decision, q.decided_by_id,
           CASE WHEN q.screen IS NULL THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object('screen', q.screen, 'steps', '[]'::jsonb)) END,
           q.evidence,
           #{notes("q")},
           q.inserted_at, q.updated_at
    FROM qa_findings q
    """
  end

  # Raised in round 1 when it was, and ruled when it last changed, since that is all that was kept.
  defp notes(table \\ "findings") do
    """
    jsonb_build_array(jsonb_build_object('round', 1, 'kind', 'raised',
                                         'at', to_char(#{table}.inserted_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))) ||
    CASE WHEN #{table}.decision IS NULL THEN '[]'::jsonb
         ELSE jsonb_build_array(jsonb_build_object('round', 1, 'kind', 'ruling', 'decision', #{table}.decision,
                                                   'by_id', #{table}.decided_by_id,
                                                   'at', to_char(#{table}.updated_at,
                                                                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))) END
    """
  end

  defp insert_lead_runs do
    %{rows: latest} =
      repo().query!("""
      SELECT DISTINCT ON (t.id) t.id, t.stage IN ('review', 'qa', 'demo'), r.started_at, r.completed_at, lead.id
      FROM tasks t
      JOIN runs r ON r.task_id = t.id
      JOIN roles old_role ON old_role.id = r.role_id AND old_role.stage IN ('review', 'qa', 'demo')
      JOIN roles lead ON lead.project_id = t.project_id AND lead.stage = 'review_lead'
      WHERE NOT EXISTS (SELECT 1 FROM runs l WHERE l.task_id = t.id AND l.role_id = lead.id)
      ORDER BY t.id, r.started_at DESC, r.inserted_at DESC
      """)

    for [task_id, at_review?, started_at, completed_at, role_id] <- latest do
      repo().query!(
        """
        INSERT INTO runs (id, task_id, role_id, status, stage_outcome, started_at, completed_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'finished', $4, $5, $6, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          UXID.generate!(prefix: "run"),
          task_id,
          role_id,
          if(at_review?, do: "in_progress", else: "done"),
          started_at,
          completed_at
        ]
      )
    end
  end

  # A saved review is the task's one finished pass, and a QA verdict has nothing left to read it.
  defp rewrite_files do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier] <- rows do
      rewrite_review(Path.join([scratch_path, "reviews", "#{identifier}.json"]))
      File.rm(Path.join([scratch_path, "qa", "#{identifier}.json"]))
    end
  end

  defp rewrite_review(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"saved_at" => saved_at}} when is_binary(saved_at) <- Jason.decode(content) do
      temporary = path <> ".rewrite"
      File.write!(temporary, Jason.encode!(%{passes: [%{round: 1, saved_at: saved_at, head: nil}]}))
      File.rename!(temporary, path)
    end
  end
end

defmodule Rail.Pipeline.Actions.CountAttentionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup %{project: project} do
    roles =
      Map.new(Role.canonical_stages(), fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    # Each issue created answers Linear once, under a key of its own.
    task_for = fn stage ->
      n = System.unique_integer([:positive])

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_attention_#{n}", "identifier" => "ATT-#{n}", "title" => "Attention #{n}"}
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Attention #{n}"})
      {:ok, task} = Pipeline.create_task(issue, :plan)
      {:ok, task} = Pipeline.update_task(task, %{stage: stage})
      Repo.preload(task, :issue)
    end

    %{roles: roles, task_for: task_for}
  end

  test "counts each task waiting on a human once, and none that is still working", %{
    project: project,
    roles: roles,
    task_for: task_for
  } do
    now = DateTime.utc_now()
    waiting = task_for.(:engineer)
    working = task_for.(:engineer)

    {:ok, _done} =
      Pipeline.create_run(%{
        task_id: waiting.id,
        role_id: roles[:engineer].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.shift(now, hour: -2),
        completed_at: DateTime.shift(now, hour: -1)
      })

    {:ok, _running} =
      Pipeline.create_run(%{task_id: working.id, role_id: roles[:engineer].id, status: :running, started_at: now})

    assert Pipeline.count_attention() == 1
    assert Pipeline.count_attention(project_id: [project.id]) == 1
    assert Pipeline.count_attention(project_id: ["prj_other"]) == 0
    assert Pipeline.count_attention(project_id: []) == 0
  end

  # Review is worked by the Review lead, so it is the lead's runs that count there.
  test "only the latest run at a task's stage counts, not one it has retried", %{roles: roles, task_for: task_for} do
    now = DateTime.utc_now()
    task = task_for.(:review)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:review_lead].id,
        status: :failed,
        error: "3 of 11 checks failed",
        started_at: DateTime.shift(now, hour: -2),
        completed_at: DateTime.shift(now, hour: -1)
      })

    {:ok, _retry} =
      Pipeline.create_run(%{task_id: task.id, role_id: roles[:review_lead].id, status: :running, started_at: now})

    assert Pipeline.count_attention() == 0
  end

  test "a task at Review waits on its Review lead's run", %{roles: roles, task_for: task_for} do
    task = task_for.(:review)

    {:ok, _finished} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:review_lead].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    assert Pipeline.count_attention() == 1
  end

  test "a run at a stage the task has left is not counted", %{roles: roles, task_for: task_for} do
    task = task_for.(:engineer)

    {:ok, _approved} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    assert Pipeline.count_attention() == 0
  end

  test "a newer run at a stage the task was sent back from does not hide the one at its own stage", %{
    roles: roles,
    task_for: task_for
  } do
    now = DateTime.utc_now()
    task = task_for.(:engineer)

    {:ok, _done} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.shift(now, hour: -3),
        completed_at: DateTime.shift(now, hour: -2)
      })

    {:ok, _reviewed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:review_lead].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.shift(now, hour: -1),
        completed_at: now
      })

    assert Pipeline.count_attention() == 1
  end

  test "a task whose issue shipped is not counted", %{roles: roles, task_for: task_for} do
    task = task_for.(:engineer)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "Exited with code 2",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    task.issue |> Issue.linear_changeset(%{completed_at: DateTime.utc_now()}) |> Repo.update!()

    assert Pipeline.count_attention() == 0
  end

  test "each child of a split waiting on a person counts once, a failed one too, and the parent never", %{
    project: project,
    roles: roles
  } do
    now = DateTime.utc_now()

    for {identifier, title} <- [
          {"ATT-SPL", "Work on ATT-SPL"},
          {"ATT-S1", "Child ATT-S1"},
          {"ATT-S2", "Child ATT-S2"},
          {"ATT-S3", "Child ATT-S3"}
        ] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on ATT-SPL"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    [blocked, failed, waiting] =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"ATT-S1", []}, {"ATT-S2", []}, {"ATT-S3", [1]}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)

        part = %{
          number: number,
          builds_on: builds_on,
          builds_screen: false,
          plan: "## Implementation plan\n\nPart #{number}."
        }

        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    # The parent's own Plan run, latched done at approval.
    {:ok, _plan} =
      Pipeline.create_run(%{
        task_id: parent.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        started_at: now
      })

    {:ok, _blocked} =
      Pipeline.create_run(%{
        task_id: blocked.id,
        role_id: roles[:engineer].id,
        status: :blocked_on_input,
        started_at: now
      })

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: failed.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "It broke.",
        started_at: now
      })

    assert Pipeline.count_attention(project_id: [project.id]) == 2

    # Canceling the first takes it off its owner's list, and blocks the third, which builds on it.
    blocked.issue |> Issue.linear_changeset(%{state: :canceled}) |> Repo.update!()
    assert Pipeline.count_attention(project_id: [project.id]) == 2

    waiting.issue |> Issue.linear_changeset(%{state: :canceled}) |> Repo.update!()
    assert Pipeline.count_attention(project_id: [project.id]) == 1
  end
end

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
      {:ok, task} = Pipeline.create_task(issue, :product)
      {:ok, task} = Pipeline.update_task(task, %{stage: stage})
      Repo.preload(task, :issue)
    end

    %{roles: roles, task_for: task_for}
  end

  test "counts each task waiting on a human once, and none that is still working", %{
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
  end

  test "only the latest run at a task's stage counts, not one it has retried", %{roles: roles, task_for: task_for} do
    now = DateTime.utc_now()
    task = task_for.(:qa)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:qa].id,
        status: :failed,
        error: "3 of 11 checks failed",
        started_at: DateTime.shift(now, hour: -2),
        completed_at: DateTime.shift(now, hour: -1)
      })

    {:ok, _retry} =
      Pipeline.create_run(%{task_id: task.id, role_id: roles[:qa].id, status: :running, started_at: now})

    assert Pipeline.count_attention() == 0
  end

  test "a run at a stage the task has left is not counted", %{roles: roles, task_for: task_for} do
    task = task_for.(:design)

    {:ok, _approved} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
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
        role_id: roles[:review].id,
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
end

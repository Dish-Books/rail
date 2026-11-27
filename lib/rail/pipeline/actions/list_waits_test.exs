defmodule Rail.Pipeline.Actions.ListWaitsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    roles =
      Map.new(Role.canonical_stages(), fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    [owner, teammate] =
      for name <- ["waits", "waits_mate"] do
        id = System.unique_integer([:positive])

        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "#{name}_#{id}",
            login: "#{name}_#{id}",
            name: name,
            email: "#{name}_#{id}@example.com"
          })

        user
      end

    task_for = fn stage ->
      {:ok, issue} =
        Issues.create_issue(system_scope(), project, %{
          title: "Waits #{System.unique_integer([:positive])}",
          owner_user_id: owner.id
        })

      {:ok, task} = Pipeline.create_task(issue, :plan)
      {:ok, task} = Pipeline.update_task(task, %{stage: stage})
      task
    end

    %{roles: roles, owner: owner, teammate: teammate, task_for: task_for}
  end

  test "lists the owner's questions, plan to review and failed run oldest first, with the same ids on every call", %{
    project: project,
    roles: roles,
    owner: owner,
    task_for: task_for
  } do
    now = DateTime.utc_now()
    failing = task_for.(:engineer)

    {:ok, %Run{id: failed_id, wait_started_at: %DateTime{} = failed_at}} =
      Pipeline.create_run(%{
        task_id: failing.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "Exited with code 1",
        started_at: now
      })

    reviewing = task_for.(:plan)

    {:ok, %Run{id: planned_id, wait_started_at: %DateTime{} = planned_at}} =
      Pipeline.create_run(%{
        task_id: reviewing.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        started_at: now
      })

    asking = task_for.(:plan)

    {:ok, %Run{id: asking_id} = run} =
      Pipeline.create_run(%{task_id: asking.id, role_id: roles[:plan].id, status: :running, started_at: now})

    {:ok, %{asked: [_first, _second, %Question{id: newest_id, inserted_at: asked_at}]}} =
      Pipeline.ask_questions(
        run,
        for(prompt <- ["Which database?", "Behind a flag?", "Who signs off?"], do: %{"prompt" => prompt})
      )

    {:ok, _parked} = Pipeline.update_run(run, %{status: :blocked_on_input})
    failed_wait = "#{failed_id}:#{DateTime.to_unix(failed_at, :microsecond)}"
    planned_wait = "#{planned_id}:#{DateTime.to_unix(planned_at, :microsecond)}"
    questions_wait = "#{asking_id}:#{newest_id}"

    for _call <- 1..2 do
      assert [
               %{kind: :failed, id: ^failed_wait, since: ^failed_at, run: %Run{id: ^failed_id}},
               %{kind: :review, id: ^planned_wait, since: ^planned_at, run: %Run{id: ^planned_id}},
               %{kind: :questions, id: ^questions_wait, since: ^asked_at, run: %Run{id: ^asking_id}}
             ] = Pipeline.list_waits(owner_user_id: owner.id, project_id: [project.id])
    end

    assert [] = Pipeline.list_waits(project_id: ["prj_other"])
  end

  test "a second round of questions is a new wait, and answers sent before the agent restarts leave none", %{
    roles: roles,
    task_for: task_for
  } do
    task = task_for.(:plan)

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{task_id: task.id, role_id: roles[:plan].id, status: :running, started_at: DateTime.utc_now()})

    {:ok, %{asked: [%Question{id: first_id}]}} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])
    {:ok, parked} = Pipeline.update_run(run, %{status: :blocked_on_input})
    first_wait = "#{run_id}:#{first_id}"

    assert [%{kind: :questions, id: ^first_wait}] = Pipeline.list_waits()

    Repo.update_all(from(q in Question, where: q.run_id == ^run_id), set: [delivered_at: DateTime.utc_now()])

    assert [] = Pipeline.list_waits()

    {:ok, resumed} = Pipeline.update_run(parked, %{status: :running})

    assert [] = Pipeline.list_waits()

    {:ok, %{asked: [%Question{id: second_id}]}} = Pipeline.ask_questions(resumed, [%{"prompt" => "Behind a flag?"}])
    {:ok, _parked} = Pipeline.update_run(resumed, %{status: :blocked_on_input})
    second_wait = "#{run_id}:#{second_id}"

    assert [%{kind: :questions, id: ^second_wait}] = Pipeline.list_waits()
  end

  test "a turn that fails after asking keeps its questions' id once its round is registered", %{
    roles: roles,
    task_for: task_for
  } do
    task = task_for.(:plan)

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{task_id: task.id, role_id: roles[:plan].id, status: :running, started_at: DateTime.utc_now()})

    {:ok, %{asked: [%Question{id: question_id}]}} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])
    {:ok, failed} = Pipeline.update_run(run, %{status: :finished, exit_code: 1, error: "Exited with code 1"})
    wait = "#{run_id}:#{question_id}"

    assert [%{kind: :questions, id: ^wait}] = Pipeline.list_waits()

    Repo.update_all(from(q in Question, where: q.run_id == ^run_id), set: [status: :pending])
    {:ok, _parked} = Pipeline.update_run(failed, %{status: :blocked_on_input})

    assert [%{kind: :questions, id: ^wait}] = Pipeline.list_waits()
  end

  test "a failed run keeps its id through a write that starts no wait, and failing again after a retry is a new wait", %{
    roles: roles,
    task_for: task_for
  } do
    task = task_for.(:engineer)

    {:ok, failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "Exited with code 1",
        started_at: DateTime.utc_now()
      })

    assert [%{kind: :failed, id: first_wait}] = Pipeline.list_waits()

    {:ok, touched} = Pipeline.update_run(failed, %{review_on_ci_pass: true})

    assert [%{kind: :failed, id: ^first_wait}] = Pipeline.list_waits()

    {:ok, retried} = Pipeline.update_run(touched, %{status: :running, error: nil})

    assert [] = Pipeline.list_waits()

    {:ok, _failed_again} = Pipeline.update_run(retried, %{status: :failed, error: "Exited with code 2"})

    assert [%{kind: :failed, id: second_wait}] = Pipeline.list_waits()
    assert second_wait != first_wait
  end

  test "a run at work or stopped without a verdict waits on nobody, and a custom stage stopped with its file saved waits on review",
       %{project: project, roles: roles, owner: owner, task_for: task_for} do
    now = DateTime.utc_now()

    for status <- [:running, :waiting_for_resources, :waiting_for_usage, :finished] do
      task = task_for.(:engineer)

      {:ok, _run} =
        Pipeline.create_run(%{task_id: task.id, role_id: roles[:engineer].id, status: status, started_at: now})
    end

    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each changed dependency's license."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{title: "Dependency updates", stages: stages, owner_user_id: owner.id})

    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, license_check} = Roles.get_custom_stage_role(project.id, "License check")

    {:ok, %Run{id: checking_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: license_check.id, status: :finished, started_at: now})

    assert [] = Pipeline.list_waits()

    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "sweet_xml 0.7.5 is AGPL-3.0."})

    assert [%{kind: :review, run: %Run{id: ^checking_id}}] = Pipeline.list_waits()
  end

  test "a reassigned issue's wait moves to its new owner with the same id", %{
    roles: roles,
    owner: owner,
    teammate: teammate,
    task_for: task_for
  } do
    task = task_for.(:engineer)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "Exited with code 1",
        started_at: DateTime.utc_now()
      })

    assert [%{id: wait}] = Pipeline.list_waits(owner_user_id: owner.id)
    assert [] = Pipeline.list_waits(owner_user_id: teammate.id)

    {:ok, issue} = Issues.get_issue(task.issue_id)
    {:ok, _reassigned} = Issues.update_issue(issue, %{owner_user_id: teammate.id})

    assert [] = Pipeline.list_waits(owner_user_id: owner.id)
    assert [%{id: ^wait}] = Pipeline.list_waits(owner_user_id: teammate.id)
  end

  test "a run the old code settled after the backfill is named by when it completed until it is stamped", %{
    roles: roles,
    task_for: task_for
  } do
    completed_at = DateTime.shift(DateTime.utc_now(), minute: -5)
    task = task_for.(:engineer)

    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        error: "Exited with code 1",
        started_at: completed_at,
        completed_at: completed_at
      })

    Repo.update_all(from(r in Run, where: r.id == ^run_id), set: [wait_started_at: nil])
    wait = "#{run_id}:#{DateTime.to_unix(completed_at, :microsecond)}"

    assert [%{kind: :failed, id: ^wait, since: ^completed_at}] = Pipeline.list_waits()
  end
end

defmodule Rail.Pipeline.Actions.ListQuestionsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo
  alias Rail.Roles

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    roles =
      Map.new([:plan, :engineer, :review, :qa, :demo], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_list_questions_1",
              "identifier" => "LQS-1",
              "title" => "List Questions Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Questions Issue"})

    {:ok, task} = Pipeline.create_task(issue, :plan)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    %{project: project, issue: issue, task: task, run: run, roles: roles}
  end

  test "lists questions by task and supports order_by", %{task: task, run: run} do
    q1 = Repo.insert!(%Question{task_id: run.task_id, run_id: run.id, prompt: "First"})
    {:ok, _dismissed} = Pipeline.dismiss_question(q1)
    %Question{id: q2_id} = q2 = Repo.insert!(%Question{task_id: run.task_id, run_id: run.id, prompt: "Second"})

    desc_order = Pipeline.list_questions(task, order_by: [desc: :inserted_at])
    assert Enum.map(desc_order, & &1.id) == [q2.id, q1.id]

    asc_order = Pipeline.list_questions(task, order_by: [asc: :inserted_at])
    assert Enum.map(asc_order, & &1.id) == [q1.id, q2.id]

    assert [%Question{id: ^q2_id}] = Pipeline.list_questions(task, status: :pending)
  end

  test "covers every run of the task", %{task: task, run: run, roles: roles} do
    {:ok, other_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    first = Repo.insert!(%Question{task_id: run.task_id, run_id: run.id, prompt: "From plan?"})

    second = Repo.insert!(%Question{task_id: other_run.task_id, run_id: other_run.id, prompt: "From engineer?"})

    assert Enum.map(Pipeline.list_questions(task, order_by: [asc: :inserted_at]), & &1.id) == [first.id, second.id]
  end

  test "get_question", %{run: run} do
    %Question{id: expected_id} = Repo.insert!(%Question{task_id: run.task_id, run_id: run.id, prompt: "Which option?"})

    assert {:ok, %Question{id: ^expected_id}} = Pipeline.get_question(expected_id)
    assert {:error, :not_found} = Pipeline.get_question("qst_nonexistent")
  end
end

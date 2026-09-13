defmodule Rail.Pipeline.Actions.ListQuestionsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Questions Project 7201",
        github_repo: "org/list-questions-7201",
        github_installation_id: 7201,
        linear_workspace: %{
          name: "List Questions Workspace",
          external_id: "lin_ws_list_questions",
          token: "lin_api_token_list_questions",
          webhook_secret: "whsec_list_questions"
        },
        linear_team_key: "P7201",
        default_branch: "main",
        clone_path: "/tmp/repos/list-questions-7201",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

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

    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    %{project: project, issue: issue, task: task, run: run, roles: roles}
  end

  test "lists questions by task and supports order_by", %{task: task, run: run} do
    {:ok, q1} = Pipeline.register_question(run, %DetectedQuestion{prompt: "First"})
    {:ok, _dismissed} = Pipeline.dismiss_question(q1)
    {:ok, %Question{id: q2_id} = q2} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Second"})

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
        role_id: roles[:design].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "From product?"})

    {:ok, second} =
      Pipeline.register_question(Repo.preload(other_run, task: :issue), %DetectedQuestion{prompt: "From design?"})

    assert Enum.map(Pipeline.list_questions(task, order_by: [asc: :inserted_at]), & &1.id) == [first.id, second.id]
  end

  test "get_question", %{run: run} do
    {:ok, %Question{id: expected_id}} =
      Pipeline.register_question(run, %DetectedQuestion{prompt: "Which option?"})

    assert {:ok, %Question{id: ^expected_id}} = Pipeline.get_question(expected_id)
    assert {:error, :not_found} = Pipeline.get_question("qst_nonexistent")
  end
end

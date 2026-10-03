defmodule Rail.Pipeline.Actions.DismissRoundTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_dismiss_round_1",
              "identifier" => "DSR-1",
              "title" => "Dismiss Round Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Dismiss Round Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_dismiss_round",
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    %{task: task, role: role, run: run}
  end

  test "an all-dismissed round closes without a message", %{run: run, role: role} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})
    {:ok, _dismissed} = Pipeline.dismiss_question(first)
    {:ok, _dismissed} = Pipeline.dismiss_question(second)

    reject(&Tools.start_os_process/2)

    assert {:ok, %Run{status: :finished, stage_outcome: :in_progress}} =
             run |> Repo.reload!() |> Repo.preload(:role) |> Pipeline.dismiss_round()

    assert %Question{delivered_at: %DateTime{}} = Repo.reload!(first)
    assert %Question{delivered_at: %DateTime{}} = Repo.reload!(second)

    assert ["[rail] Questions dismissed. Nothing was sent to #{role.name}."] ==
             run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end

  test "a round with a question still open is not closed", %{run: run} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, _second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})
    {:ok, _dismissed} = Pipeline.dismiss_question(first)

    assert {:error, :questions_pending} = run |> Repo.reload!() |> Repo.preload(:role) |> Pipeline.dismiss_round()
    refute Repo.reload!(first).delivered_at
  end

  test "a round with an answer in it is sent, not dismissed", %{run: run} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})
    {:ok, _answered} = Pipeline.answer_question(system_scope(), first, "Postgres")
    {:ok, _dismissed} = Pipeline.dismiss_question(second)

    assert {:error, :answers_to_send} = run |> Repo.reload!() |> Repo.preload(:role) |> Pipeline.dismiss_round()
    refute Repo.reload!(first).delivered_at
    assert %Run{status: :blocked_on_input} = Repo.reload!(run)
  end

  test "a run with no round has nothing to dismiss", %{run: run} do
    assert {:error, :nothing_to_send} = run |> Repo.reload!() |> Repo.preload(:role) |> Pipeline.dismiss_round()
  end

  test "a run no longer parked on the round keeps its status", %{run: run} do
    {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Rebase onto main?"})
    {:ok, _dismissed} = Pipeline.dismiss_question(question)

    # Updating the branch resumes the run without anyone answering what it asked.
    {:ok, resumed} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :running})

    assert {:ok, %Run{status: :running}} = resumed |> Repo.preload(:role) |> Pipeline.dismiss_round()
    assert %Question{delivered_at: %DateTime{}} = Repo.reload!(question)
  end
end

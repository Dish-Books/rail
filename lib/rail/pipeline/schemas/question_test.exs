defmodule Rail.Pipeline.Schemas.QuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Question Schema Workspace",
        external_id: "lin_ws_question_schema",
        token: "lin_api_token_question_schema",
        webhook_secret: "whsec_question_schema"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Question Schema Project 7501",
        github_repo: "org/question-schema-7501",
        github_installation_id: 7501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_question_schema_7501",
        linear_team_key: "P7501",
        default_branch: "main",
        clone_path: "/tmp/repos/question-schema-7501",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_question_schema_1",
      "identifier" => "QSC-1",
      "title" => "Question Schema Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Question Schema Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    %{backend: backend, project: project, issue: issue, task: task, run: run}
  end

  test "changeset validates required fields" do
    assert %{
             task_id: ["can't be blank"],
             run_id: ["can't be blank"],
             prompt: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{}))

    assert %{
             status: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{status: nil}))
  end

  test "changeset accepts valid attributes and sets defaults", %{task: task, run: run} do
    attrs = %{
      run_id: run.id,
      prompt: "Which approach should we take?",
      options: ["Approach 1", "Approach 2"],
      context_summary: "Detailed summary context",
      answer: "Approach 1",
      status: :answered,
      answered_at: DateTime.utc_now()
    }

    changeset = Question.changeset(%Question{}, attrs, task.id)

    assert changeset.valid?
    assert get_field(changeset, :task_id) == task.id
    assert get_field(changeset, :status) == :answered
    assert get_field(changeset, :options) == ["Approach 1", "Approach 2"]
  end

  test "changeset validates status enum", %{task: task} do
    assert %{status: ["is invalid"]} =
             errors_on(
               Question.changeset(
                 %Question{},
                 %{prompt: "Prompt?", status: "invalid_status"},
                 task.id
               )
             )
  end

  test "statuses/0, pending?/1, and resolved?/1 helpers" do
    assert Question.statuses() == [:pending, :unanswered, :answered, :dismissed]

    assert Question.pending?(:pending)
    refute Question.pending?(:answered)
    refute Question.pending?(:dismissed)
    refute Question.pending?(:invalid)
    refute Question.pending?(nil)
    refute Question.pending?("pending")
    refute Question.pending?(123)

    assert Question.resolved?(:answered)
    assert Question.resolved?(:dismissed)
    refute Question.resolved?(:pending)
    refute Question.resolved?(:invalid)
    refute Question.resolved?(nil)
    refute Question.resolved?("answered")
    refute Question.resolved?(123)
  end

  test "validates foreign key on task_id", %{run: run} do
    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %Question{}
             |> Question.changeset(
               %{prompt: "Missing task prompt", run_id: run.id},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task and run", %{task: task, run: %Run{id: run_id} = run} do
    %Task{id: task_id} = task = task

    question =
      Repo.insert!(
        Question.changeset(
          %Question{},
          %{
            prompt: "Question for role?",
            run_id: run.id
          },
          task.id
        )
      )

    preloaded = Repo.preload(question, [:task, :run])

    assert %Question{
             task: %Task{id: ^task_id},
             run: %Run{id: ^run_id}
           } = preloaded
  end
end

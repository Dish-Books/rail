defmodule Rail.Pipeline.Schemas.QuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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

    {:ok, issue} = Issues.capture_issue(scope, project, "Question Schema Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "changeset validates required fields" do
    assert %{
             task_id: ["can't be blank"],
             prompt: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{}))

    assert %{
             status: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{status: nil}))
  end

  test "changeset accepts valid attributes and sets defaults", %{task: task} do
    attrs = %{
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

  test "validates foreign key on task_id", %{task: _task} do
    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %Question{}
             |> Question.changeset(
               %{prompt: "Missing task prompt"},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task and role", %{task: task} do
    %Task{id: task_id} = task = task

    {:ok, %Role{id: role_id} = role} =
      Roles.create_role(system_scope(), task.project_id, %{
        name: "Role 7502",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 7502."
      })

    question =
      Repo.insert!(
        Question.changeset(
          %Question{},
          %{
            prompt: "Question for role?",
            role_id: role.id
          },
          task.id
        )
      )

    preloaded = Repo.preload(question, [:task, :role])

    assert %Question{
             task: %Task{id: ^task_id},
             role: %Role{id: ^role_id}
           } = preloaded
  end
end

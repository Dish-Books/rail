defmodule Rail.Pipeline.Schemas.QuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  test "factory builds a valid question struct" do
    assert %Question{
             task_id: "tsk_" <> _id,
             prompt: "Should we proceed" <> _prompt,
             options: ["Option A", "Option B"],
             status: :pending
           } = Question.factory()
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

  test "changeset accepts valid attributes and sets defaults" do
    task = create_test_task()

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

  test "changeset validates status enum" do
    task = create_test_task()

    assert %{status: ["is invalid"]} =
             errors_on(
               Question.changeset(
                 %Question{},
                 %{prompt: "Prompt?", status: "invalid_status"},
                 task.id
               )
             )
  end

  test "validates foreign key on task_id" do
    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %Question{}
             |> Question.changeset(
               %{prompt: "Missing task prompt"},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task and role" do
    %Task{id: task_id} = task = create_test_task()
    %Role{id: role_id} = role = create_test_role(%{project_id: task.project_id})

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

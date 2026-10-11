defmodule Rail.Mcp.Utils.RunToolAskQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolAskQuestions

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RAQ-1")
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, %{id: run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{task: task, run_id: run_id, opts: [os_process: %OsProcess{run_id: run_id, task_id: task.id}]}
  end

  test "files the round on the calling run, prompts and options in order, held until the turn ends", %{
    task: task,
    run_id: run_id,
    opts: opts
  } do
    questions = [
      %{"prompt" => "Which database?", "options" => ["Postgres", "SQLite"]},
      %{"prompt" => "Behind a flag?"}
    ]

    assert {:ok, "Asked 2 questions. The human sees the round when your turn ends."} =
             run_tool_ask_questions(task, %{"questions" => questions}, opts)

    assert [
             %Question{run_id: ^run_id, status: :asked, prompt: "Which database?", options: ["Postgres", "SQLite"]},
             %Question{run_id: ^run_id, status: :asked, prompt: "Behind a flag?", options: []}
           ] = Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id])
  end

  test "a second call adds to the same round, and a prompt asked again is filed once", %{task: task, opts: opts} do
    assert {:ok, "Asked 1 question. " <> _rest} =
             run_tool_ask_questions(task, %{"questions" => [%{"prompt" => "Which database?"}]}, opts)

    repeated = [%{"prompt" => " which database? "}, %{"prompt" => "Which region?"}, %{"prompt" => "Which region?"}]

    assert {:ok, "Asked 1 question, and 2 already asked. " <> _rest} =
             run_tool_ask_questions(task, %{"questions" => repeated}, opts)

    assert {:ok, "Nothing new to ask: 1 question already asked this turn."} =
             run_tool_ask_questions(task, %{"questions" => [%{"prompt" => "Which region?"}]}, opts)

    assert ["Which database?", "Which region?"] =
             task |> Pipeline.list_questions(order_by: [asc: :inserted_at, asc: :id]) |> Enum.map(& &1.prompt)
  end

  test "an empty or missing list, or a list sent as text, is refused and files nothing", %{task: task, opts: opts} do
    assert {:refused, "Refused, nothing asked. questions is empty: " <> _rest} =
             run_tool_ask_questions(task, %{"questions" => []}, opts)

    assert {:refused, "Refused, nothing asked. questions is required: " <> _rest} =
             run_tool_ask_questions(task, %{}, opts)

    assert {:refused, "Refused, nothing asked. questions is required: " <> _rest} =
             run_tool_ask_questions(task, %{"questions" => ~s([{"prompt": "Which database?"}])}, opts)

    assert Pipeline.list_questions(task) == []
  end

  test "a list with any bad entry is refused whole, naming each bad entry by its number", %{task: task, opts: opts} do
    questions = [
      %{"prompt" => "Which database?", "options" => ["Postgres"]},
      "Which region?",
      %{"prompt" => "  "},
      %{"prompt" => "Behind a flag?", "options" => "Yes | No"},
      %{"prompt" => "Who reviews it?", "options" => ["Sam", 7]},
      %{"prompt" => 7}
    ]

    assert {:refused,
            "Refused, nothing asked. Question 2: it must be an object with a prompt. Question 3: prompt is required. " <>
              "Question 4: options must be a list of text. Question 5: options must be a list of text. " <>
              "Question 6: prompt must be text. Fix them and ask the whole list again."} =
             run_tool_ask_questions(task, %{"questions" => questions}, opts)

    assert Pipeline.list_questions(task) == []
  end
end

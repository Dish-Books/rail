defmodule Rail.Runs.Actions.DetectQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Actions.DetectQuestion
  alias Rail.Runs.DetectedQuestion

  test "detects a question on its own line" do
    question = DetectQuestion.detect_question("[QUESTION: Which database should we use?]")

    assert %DetectedQuestion{} = question
    assert question.prompt == "Which database should we use?"
    assert question.options == []
    assert String.starts_with?(question.id, "q-")
    assert is_nil(question.task_id)
    assert is_nil(question.role_id)
    assert is_nil(question.context_summary)
  end

  test "detects question with options" do
    line = "[QUESTION: Scope to one repo?] [OPTIONS: yes, no]"
    question = DetectQuestion.detect_question(line)

    assert %DetectedQuestion{} = question
    assert question.prompt == "Scope to one repo?"
    assert question.options == ["yes", "no"]
  end

  test "options parsing trims and rejects empty options" do
    line = "[QUESTION: Which flavor?] [OPTIONS:  vanilla , , chocolate , strawberry ]"
    question = DetectQuestion.detect_question(line)

    assert question.options == ["vanilla", "chocolate", "strawberry"]
  end

  test "detects question case-insensitively" do
    line = "[question: Should we rebase?] [options: yes, no]"
    question = DetectQuestion.detect_question(line)

    assert %DetectedQuestion{} = question
    assert question.prompt == "Should we rebase?"
    assert question.options == ["yes", "no"]
  end

  test "allows leading whitespace, blockquotes, and bullet markers" do
    assert %DetectedQuestion{prompt: "Bullet question"} =
             DetectQuestion.detect_question("- [QUESTION: Bullet question]")

    assert %DetectedQuestion{prompt: "Star bullet question"} =
             DetectQuestion.detect_question("* [QUESTION: Star bullet question]")

    assert %DetectedQuestion{prompt: "Blockquote question"} =
             DetectQuestion.detect_question("> [QUESTION: Blockquote question]")

    assert %DetectedQuestion{prompt: "Nested prefix question"} =
             DetectQuestion.detect_question("  > * -  [QUESTION: Nested prefix question]")
  end

  test "ignores question marker quoted mid-sentence in prose" do
    assert is_nil(
             DetectQuestion.detect_question("The user asked [QUESTION: what about this?] earlier in the discussion.")
           )
  end

  test "rejects placeholder prompts echoing role brief templates" do
    assert is_nil(DetectQuestion.detect_question("[QUESTION: <question>]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION: <describe your question here>]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION: ...]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION: …]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION:   . . .   ]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION: ]"))
    assert is_nil(DetectQuestion.detect_question("[QUESTION:    ]"))
  end

  test "handles nil and empty strings" do
    assert is_nil(DetectQuestion.detect_question(nil))
    assert is_nil(DetectQuestion.detect_question(""))
    assert is_nil(DetectQuestion.detect_question("   "))
  end

  test "finds question in multi-line text" do
    text = """
    Looking into the repository architecture.
    I noticed multiple potential approaches.

    * [QUESTION: Should we use Postgres or SQLite?] [OPTIONS: Postgres, SQLite]

    Let me know how to proceed.
    """

    question = DetectQuestion.detect_question(text)
    assert %DetectedQuestion{} = question
    assert question.prompt == "Should we use Postgres or SQLite?"
    assert question.options == ["Postgres", "SQLite"]
  end

  test "extracts task_id, role_id, id, and context_summary from options map" do
    opts = %{
      id: "q-custom123",
      task_id: "tsk_123",
      role_id: "rol_456",
      context_summary: "Custom context"
    }

    question = DetectQuestion.detect_question("[QUESTION: What port?]", opts)

    assert question.id == "q-custom123"
    assert question.task_id == "tsk_123"
    assert question.role_id == "rol_456"
    assert question.context_summary == "Custom context"
  end

  test "extracts task and role details from structs/maps in keyword opts" do
    opts = [
      task: %{id: "tsk_abc", title: "Add OAuth flow"},
      role: %{id: "rol_engineer"}
    ]

    question = DetectQuestion.detect_question("[QUESTION: Which OAuth provider?]", opts)

    assert question.task_id == "tsk_abc"
    assert question.role_id == "rol_engineer"
    assert question.context_summary == "Asked during: Add OAuth flow"
  end

  test "extracts context_summary from task_title option" do
    opts = [task_title: "Fix bug in billing"]
    question = DetectQuestion.detect_question("[QUESTION: Refund amount?]", opts)

    assert question.context_summary == "Asked during: Fix bug in billing"
  end

  test "extracts task and role from atom map access" do
    task = %{id: "tsk_atom", title: "Atom Title"}
    role = %{id: "rol_atom"}

    question =
      DetectQuestion.detect_question("[QUESTION: Query?]", %{task: task, role: role})

    assert question.task_id == "tsk_atom"
    assert question.role_id == "rol_atom"
    assert question.context_summary == "Asked during: Atom Title"
  end

  test "detect_questions returns every question in order, collapsing repeats" do
    text = """
    Looking at the schema.
    [QUESTION: Which database?] [OPTIONS: PG, MySQL]
    Some prose in between.
    > [QUESTION: Ship behind a flag?]
    [QUESTION: <placeholder>]
    [QUESTION: which database?]
    """

    questions = DetectQuestion.detect_questions(text, task_id: "tsk_1", role_id: "rol_1")

    assert Enum.map(questions, & &1.prompt) == ["Which database?", "Ship behind a flag?"]
    assert Enum.map(questions, & &1.options) == [["PG", "MySQL"], []]
    assert Enum.all?(questions, &(&1.task_id == "tsk_1" and &1.role_id == "rol_1"))
  end

  test "detect_questions returns an empty list when there is nothing to ask" do
    assert DetectQuestion.detect_questions("Just prose.") == []
    assert DetectQuestion.detect_questions(nil) == []
  end

  test "detect_question still returns only the first question" do
    text = "[QUESTION: First?]\n[QUESTION: Second?]"

    assert %DetectedQuestion{prompt: "First?"} = DetectQuestion.detect_question(text)
  end
end

defmodule Rail.Pipeline.Actions.BuildPromptTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  test "sends the answer, not the task again, when resuming a session" do
    opts = [
      conversation_id: "sess-abc-123",
      pending_answer: "You asked: archived bills?\nThe answer is: exclude",
      context_snippet: "house rules",
      task_description: "do the thing"
    ]

    prompt = Pipeline.build_prompt(opts)

    assert prompt =~ "The answer is: exclude"
    assert prompt =~ "Continue from where you stopped."
    refute prompt =~ "do the thing"
    refute prompt =~ "house rules"
  end

  test "a first run contains the snippet and the task" do
    opts = [
      context_snippet: "house rules",
      task_description: "do the thing"
    ]

    prompt = Pipeline.build_prompt(opts)

    assert prompt =~ "house rules"
    assert prompt =~ "do the thing"
    refute prompt =~ "Continue from where you stopped."
  end

  test "leaves role instructions out of the prompt body" do
    opts = [
      role_instructions: "Act as a principal engineer.",
      system_prompt: "Act as a principal engineer.",
      task_description: "do the thing"
    ]

    assert Pipeline.build_prompt(opts) == "do the thing\n"
  end

  test "appends plan after task description" do
    plan = "## Implementation plan\n\n**Approach**: Build it."

    opts = [
      task_description: "do the thing",
      plan: plan
    ]

    prompt = Pipeline.build_prompt(opts)

    assert prompt =~ plan

    {task_pos, _task_len} = :binary.match(prompt, "do the thing")
    {plan_pos, _plan_len} = :binary.match(prompt, plan)
    assert task_pos < plan_pos
  end

  test "skips plan when resuming a session with an answer" do
    plan = "## Implementation plan\n\n**Approach**: Build it."

    opts = [
      conversation_id: "sess-123",
      pending_answer: "My answer",
      plan: plan,
      task_description: "do the thing"
    ]

    prompt = Pipeline.build_prompt(opts)

    assert prompt =~ "My answer"
    refute prompt =~ plan
    refute prompt =~ "do the thing"
  end

  test "extracts ticket from task struct or map" do
    task = %{description: "task description text"}
    assert Pipeline.build_prompt(task: task) == "task description text\n"

    assert Pipeline.build_prompt(ticket: "explicit ticket text") == "explicit ticket text\n"
    assert Pipeline.build_prompt(description: "simple description") == "simple description\n"
  end

  test "handles empty context snippet and plan gracefully" do
    opts = [
      context_snippet: "   ",
      plan: "   ",
      task_description: "do work"
    ]

    assert Pipeline.build_prompt(opts) == "do work\n"
  end

  test "supports explicit is_resume boolean" do
    opts = [
      is_resume: true,
      pending_answer: "Done with refactor"
    ]

    prompt = Pipeline.build_prompt(opts)
    assert prompt =~ "Done with refactor"
    assert prompt =~ "Continue from where you stopped."
  end

  test "handles empty options" do
    assert Pipeline.build_prompt(%{}) == "\n"
    assert Pipeline.build_prompt(task_description: "Hello") == "Hello\n"
  end
end

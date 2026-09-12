defmodule Rail.Runs.Actions.BuildPromptTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs

  test "sends the answer, not the task again, when resuming a session" do
    opts = [
      conversation_id: "sess-abc-123",
      pending_answer: "You asked: archived bills?\nThe answer is: exclude",
      context_snippet: "house rules",
      task_description: "do the thing",
      backend: %Backend{name: :agy}
    ]

    prompt = Runs.build_prompt(opts)

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

    prompt = Runs.build_prompt(opts)

    assert prompt =~ "house rules"
    assert prompt =~ "do the thing"
    refute prompt =~ "Continue from where you stopped."
  end

  test "emits role instructions inside tags for Agy on the first run only" do
    first_opts = [
      backend: %Backend{name: :agy},
      role_instructions: "Act as a principal engineer.",
      context_snippet: "house rules",
      task_description: "do the thing"
    ]

    first_prompt = Runs.build_prompt(first_opts)

    assert String.starts_with?(
             first_prompt,
             "<role-instructions>\nAct as a principal engineer.\n</role-instructions>"
           )

    assert first_prompt =~ "house rules"
    assert first_prompt =~ "do the thing"

    resume_opts = [
      backend: %Backend{name: :agy},
      conversation_id: "sess-123",
      pending_answer: "My answer",
      role_instructions: "Act as a principal engineer."
    ]

    resume_prompt = Runs.build_prompt(resume_opts)

    refute resume_prompt =~ "<role-instructions>"
    assert String.starts_with?(resume_prompt, "My answer")

    assert resume_prompt =~ "My answer"
    assert resume_prompt =~ "Continue from where you stopped."
    refute resume_prompt =~ "do the thing"
  end

  test "claude omits role instructions from prompt body" do
    opts = [
      backend: %Backend{name: :claude},
      role_instructions: "Act as a principal engineer.",
      task_description: "do the thing"
    ]

    prompt = Runs.build_prompt(opts)

    refute prompt =~ "<role-instructions>"
    refute prompt =~ "Act as a principal engineer."
    assert prompt =~ "do the thing"
  end

  test "appends plan after task description" do
    plan = "## Implementation plan\n\n**Approach**: Build it."

    opts = [
      task_description: "do the thing",
      plan: plan
    ]

    prompt = Runs.build_prompt(opts)

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

    prompt = Runs.build_prompt(opts)

    assert prompt =~ "My answer"
    refute prompt =~ plan
    refute prompt =~ "do the thing"
  end

  test "extracts ticket from task struct or map" do
    task = %{description: "task description text"}
    assert Runs.build_prompt(task: task) == "task description text\n"

    assert Runs.build_prompt(ticket: "explicit ticket text") == "explicit ticket text\n"
    assert Runs.build_prompt(description: "simple description") == "simple description\n"
  end

  test "handles empty context snippet and plan gracefully" do
    opts = [
      context_snippet: "   ",
      plan: "   ",
      task_description: "do work"
    ]

    assert Runs.build_prompt(opts) == "do work\n"
  end

  test "supports explicit is_resume boolean" do
    opts = [
      is_resume: true,
      pending_answer: "Done with refactor"
    ]

    prompt = Runs.build_prompt(opts)
    assert prompt =~ "Done with refactor"
    assert prompt =~ "Continue from where you stopped."
  end

  test "handles empty options and non-standard backends" do
    assert Runs.build_prompt(%{}) == "\n"
    assert Runs.build_prompt(backend: nil, task_description: "Hello") == "Hello\n"
    assert Runs.build_prompt(backend: 123, task_description: "Hello") == "Hello\n"
  end
end

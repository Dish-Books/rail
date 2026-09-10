defmodule Rail.Runs.PromptBuilderTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.PromptBuilder

  test "sends the answer, not the task again, when resuming a session" do
    opts = [
      conversation_id: "sess-abc-123",
      pending_answer: "You asked: archived bills?\nThe answer is: exclude",
      context_snippet: "house rules",
      task_description: "do the thing",
      backend: :agy
    ]

    prompt = PromptBuilder.build_prompt(opts)

    assert prompt =~ "The answer is: exclude"
    assert prompt =~ "Continue from where you stopped."
    refute prompt =~ "do the thing"
    refute prompt =~ "house rules"
  end

  test "carries the answer with the task when there is no session" do
    opts = %{
      pending_answer: "The answer is: exclude",
      task_description: "do the thing"
    }

    prompt = PromptBuilder.build_prompt(opts)

    assert prompt =~ "do the thing"
    assert prompt =~ "The answer is: exclude"
    refute prompt =~ "Continue from where you stopped."
  end

  test "a first run contains the snippet and the task" do
    opts = [
      context_snippet: "house rules",
      task_description: "do the thing"
    ]

    prompt = PromptBuilder.build_prompt(opts)

    assert prompt =~ "house rules"
    assert prompt =~ "do the thing"
    refute prompt =~ "Continue from where you stopped."
  end

  test "emits role instructions inside tags first for Agy on first run and resume" do
    first_opts = [
      backend: :agy,
      role_instructions: "Act as a principal engineer.",
      context_snippet: "house rules",
      task_description: "do the thing"
    ]

    first_prompt = PromptBuilder.build_prompt(first_opts)

    assert String.starts_with?(
             first_prompt,
             "<role-instructions>\nAct as a principal engineer.\n</role-instructions>"
           )

    assert first_prompt =~ "house rules"
    assert first_prompt =~ "do the thing"

    resume_opts = [
      backend: "agy",
      conversation_id: "sess-123",
      pending_answer: "My answer",
      role_instructions: "Act as a principal engineer."
    ]

    resume_prompt = PromptBuilder.build_prompt(resume_opts)

    assert String.starts_with?(
             resume_prompt,
             "<role-instructions>\nAct as a principal engineer.\n</role-instructions>"
           )

    assert resume_prompt =~ "My answer"
    assert resume_prompt =~ "Continue from where you stopped."
    refute resume_prompt =~ "do the thing"
  end

  test "claude omits role instructions from prompt body" do
    opts = [
      backend: :claude,
      role_instructions: "Act as a principal engineer.",
      task_description: "do the thing"
    ]

    prompt = PromptBuilder.build_prompt(opts)

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

    prompt = PromptBuilder.build_prompt(opts)

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

    prompt = PromptBuilder.build_prompt(opts)

    assert prompt =~ "My answer"
    refute prompt =~ plan
    refute prompt =~ "do the thing"
  end

  test "bypasses prompt construction when prompt_override is given" do
    opts = %{
      prompt_override: "Direct chat turn message",
      task_description: "do the thing"
    }

    assert PromptBuilder.build_prompt(opts) == "Direct chat turn message"
  end

  test "extracts ticket from task struct or map" do
    task = %{description: "task description text"}
    assert PromptBuilder.build_prompt(task: task) == "task description text\n"

    assert PromptBuilder.build_prompt(ticket: "explicit ticket text") == "explicit ticket text\n"
    assert PromptBuilder.build_prompt(description: "simple description") == "simple description\n"
  end

  test "handles empty context snippet and plan gracefully" do
    opts = [
      context_snippet: "   ",
      plan: "   ",
      task_description: "do work"
    ]

    assert PromptBuilder.build_prompt(opts) == "do work\n"
  end

  test "supports explicit is_resume boolean" do
    opts = [
      is_resume: true,
      pending_answer: "Done with refactor"
    ]

    prompt = PromptBuilder.build_prompt(opts)
    assert prompt =~ "Done with refactor"
    assert prompt =~ "Continue from where you stopped."
  end

  test "handles empty options and non-standard backends" do
    assert PromptBuilder.build_prompt(%{}) == "\n"
    assert PromptBuilder.build_prompt(backend: nil, task_description: "Hello") == "Hello\n"
    assert PromptBuilder.build_prompt(backend: 123, task_description: "Hello") == "Hello\n"
  end

  test "chat_prompt and build_chat_prompt helpers" do
    assert PromptBuilder.chat_prompt("How are you?") =~ "How are you?"
    assert PromptBuilder.chat_prompt(nil) =~ "Human message:\n\n"
    assert PromptBuilder.build_chat_prompt("Direct call") =~ "Direct call"
    assert Rail.Runs.chat_prompt("Via Runs") =~ "Via Runs"
    assert Rail.Runs.build_chat_prompt("Via Runs 2") =~ "Via Runs 2"
  end
end

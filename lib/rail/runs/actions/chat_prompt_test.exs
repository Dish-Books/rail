defmodule Rail.Runs.Actions.ChatPromptTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Actions.ChatPrompt

  test "wraps the human message in a direct conversation turn" do
    prompt = ChatPrompt.chat_prompt("How are you?")

    assert prompt =~ "Human message:\nHow are you?"
    assert prompt =~ "Do NOT re-run your stage pass."
  end

  test "treats a non-binary message as empty" do
    assert ChatPrompt.chat_prompt(nil) =~ "Human message:\n\n"
  end

  test "is reachable through the Runs context" do
    assert Rail.Runs.chat_prompt("Via Runs") =~ "Via Runs"
  end
end

defmodule Rail.Pipeline.Actions.ChatPromptTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  test "wraps the human message in a direct conversation turn" do
    prompt = Pipeline.chat_prompt("How are you?")

    assert prompt =~ "Human message:\nHow are you?"
    assert prompt =~ "Do NOT re-run your stage pass."
  end

  test "treats a non-binary message as empty" do
    assert Pipeline.chat_prompt(nil) =~ "Human message:\n\n"
  end

  test "is reachable through the Pipeline context" do
    assert Pipeline.chat_prompt("Via Pipeline") =~ "Via Pipeline"
  end
end

defmodule Rail.Pipeline.Actions.ChatPrompt do
  @moduledoc false

  @doc """
  Constructs the interactive chat turn prompt for the agent.
  """
  def chat_prompt(message) when is_binary(message) do
    """
    The human has a question or comment about this task.

    This is a direct conversation turn with you, not a new stage instruction:
    - Answer the human's question directly and concisely based on your previous work on this task.
    - Do NOT re-run your stage pass.
    - Do NOT output any stage verdict (such as "VERDICT: ...").
    - Do NOT modify files on the branch unless the human explicitly asks you to make code changes.

    Human message:
    #{message}
    """
  end

  def chat_prompt(_other), do: chat_prompt("")
end

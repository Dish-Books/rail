defmodule Rail.Mcp.Utils.RunToolSupportRead do
  @moduledoc """
  Reads the support conversation the task's issue was created from, as Support holds it now, so a plan works from
  what the customer said rather than a copy taken when the ticket was made.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation

  @doc "Returns the conversation `task`'s issue references as Markdown, or a sentence saying it has none."
  def run_tool_support_read(%Task{issue: %Issue{support_conversation_id: id}}, _arguments, _opts) when is_binary(id) do
    {:ok, conversation} = Support.get_support_conversation(Scope.for_system(), id)
    {:ok, Conversation.calculate_transcript(conversation)}
  end

  def run_tool_support_read(%Task{}, _arguments, _opts),
    do: {:ok, "This issue was not created from a support conversation, so there is none to read."}
end

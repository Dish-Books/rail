defmodule Rail.Support.Workers.RunSupportAgent do
  @moduledoc """
  Runs the support agent once on a conversation.
  """
  use Oban.Worker,
    queue: :support_agent,
    max_attempts: 3,
    unique: [keys: [:conversation_id], period: :infinity, states: [:available, :scheduled]]

  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => id}}) do
    case Repo.get(Conversation, id) do
      %Conversation{} = conversation -> Support.run_support_agent(conversation)
      nil -> :ok
    end
  end
end

defmodule Rail.Support.Utils.RequestSupportDraft do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.RunSupportAgent

  @doc """
  Marks the conversation as drafting and queues a pass. An earlier request's time is kept.
  """
  def request_support_draft(%Conversation{id: id}) do
    now = DateTime.utc_now()

    {1, [conversation]} =
      Repo.update_all(
        from(c in Conversation,
          where: c.id == ^id,
          select: c,
          update: [
            set: [
              drafting_since: fragment("coalesce(?, ?)", c.drafting_since, type(^now, :utc_datetime_usec)),
              agent_error: nil
            ]
          ]
        ),
        []
      )

    {:ok, _job} = Oban.insert(RunSupportAgent.new(%{"conversation_id" => id}))
    Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
    {:ok, conversation}
  end
end

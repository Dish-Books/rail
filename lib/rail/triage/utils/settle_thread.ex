defmodule Rail.Triage.Utils.SettleThread do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Triage.Schemas.Thread

  @doc """
  Works out where `thread` stands from its items, reply, messages and chat, saves it and announces it on `"triage"`.

  It is `:triaging` while a pass holds it or one is owed, `:waiting` while it has a reply to post, a ticket to
  create or a follow-up to add, or a failed pass needs a person, and `:done` once there is nothing left to send,
  the thread was dismissed, or nothing in it needed a response.
  """
  def settle_thread(%Thread{id: id}) do
    thread =
      Thread
      |> Repo.get!(id)
      |> Repo.preload([:items, :messages, :chat_messages, slack_channel: :slack_workspace])

    triggering = Enum.filter(thread.messages, &Thread.triggering?(thread, &1))

    status =
      cond do
        is_struct(thread.dismissed_at, DateTime) ->
          :done

        is_struct(thread.triage_started_at, DateTime) ->
          :triaging

        is_nil(thread.error) and (Enum.any?(triggering, &is_nil(&1.triaged_at)) or Thread.chat_owed?(thread)) ->
          :triaging

        Thread.pending?(thread) ->
          :waiting

        thread.items != [] or is_struct(thread.reply_posted_at, DateTime) ->
          :done

        Enum.all?(triggering, &is_binary(&1.no_response_reason)) ->
          :done

        true ->
          :waiting
      end

    {:ok, thread} = thread |> Ecto.Changeset.change(status: status) |> Repo.update()
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread.id})
    {:ok, thread}
  end
end

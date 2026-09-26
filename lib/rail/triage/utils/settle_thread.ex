defmodule Rail.Triage.Utils.SettleThread do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @doc """
  Works out where `thread` stands from its items and messages, saves it and
  announces it on `"triage"`.

  It is `:triaging` while a pass holds it or one is owed, `:waiting` while
  anything is left to accept or a failed pass needs a person, and `:done` once
  everything is accepted, the thread was dismissed, or nothing in it needed a
  response.
  """
  def settle_thread(%Thread{id: id}) do
    thread = Thread |> Repo.get!(id) |> Repo.preload([:items, :messages, slack_channel: :slack_workspace])
    triggering = Enum.filter(thread.messages, &Thread.triggering?(thread, &1))

    status =
      cond do
        is_struct(thread.dismissed_at, DateTime) ->
          :done

        is_struct(thread.triage_started_at, DateTime) ->
          :triaging

        is_nil(thread.error) and
            (Enum.any?(thread.items, & &1.retriaging) or Enum.any?(triggering, &is_nil(&1.triaged_at))) ->
          :triaging

        Enum.any?(thread.items, &(not Item.settled?(&1))) ->
          :waiting

        thread.items != [] or Enum.all?(triggering, &is_binary(&1.no_response_reason)) ->
          :done

        true ->
          :waiting
      end

    {:ok, thread} = thread |> Ecto.Changeset.change(status: status) |> Repo.update()
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread.id})
    {:ok, thread}
  end
end

defmodule Rail.Triage.Actions.AddTriageNote do
  @moduledoc false

  import Rail.Triage.Utils.EnqueueTriage

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Note
  alias Rail.Triage.Schemas.Thread

  @doc """
  Records a person's note on one item and triages that item again with it. A
  note may correct an assumption; either way it is never posted to Slack. The
  other items are left as they are, and a settled item or a forwarded thread takes no notes.
  """
  def add_triage_note(%Scope{} = scope, %Item{id: item_id}, attrs) do
    item = Item |> Repo.get!(item_id) |> Repo.preload(:thread)

    cond do
      Thread.forwarded?(item.thread) ->
        {:error, :forwarded}

      Item.settled?(item) ->
        {:error, :settled}

      true ->
        result =
          Repo.transaction(fn ->
            case scope |> Note.changeset(item, attrs) |> Repo.insert() do
              {:ok, note} ->
                item |> Ecto.Changeset.change(retriaging: true) |> Repo.update!()
                note

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)

        with {:ok, note} <- result do
          {:ok, _thread} = enqueue_triage(item.thread)
          {:ok, note}
        end
    end
  end
end

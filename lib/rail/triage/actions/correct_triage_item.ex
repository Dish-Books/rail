defmodule Rail.Triage.Actions.CorrectTriageItem do
  @moduledoc false

  import Rail.Triage.Utils.EnqueueTriage

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Correction
  alias Rail.Triage.Schemas.Item

  @doc """
  Records a person's correction to one item and triages that item again with it.
  The other items are left as they are. A settled item is closed to corrections.
  """
  def correct_triage_item(%Scope{} = scope, %Item{id: item_id}, attrs) do
    item = Item |> Repo.get!(item_id) |> Repo.preload(:thread)

    if Item.settled?(item) do
      {:error, :settled}
    else
      result =
        Repo.transaction(fn ->
          case scope |> Correction.changeset(item, attrs) |> Repo.insert() do
            {:ok, correction} ->
              item |> Ecto.Changeset.change(retriaging: true) |> Repo.update!()
              correction

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      with {:ok, correction} <- result do
        {:ok, _thread} = enqueue_triage(item.thread)
        {:ok, correction}
      end
    end
  end
end

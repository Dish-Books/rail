defmodule Rail.Triage.Utils.ClaimReply do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Item

  @doc """
  Claims an item's reply for `user_id` before it is posted, so two people
  accepting at once post it once. Returns `:ok`, or `{:error, :already_posted}`
  when someone else holds it.
  """
  def claim_reply(%Item{id: item_id}, user_id) do
    case Repo.update_all(from(i in Item, where: i.id == ^item_id and is_nil(i.reply_posted_by_id)),
           set: [reply_posted_by_id: user_id]
         ) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_posted}
    end
  end
end

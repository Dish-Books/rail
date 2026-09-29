defmodule Rail.Triage.Utils.ReleaseReply do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Item

  @doc """
  Gives back a reply claimed with `claim_reply/2` whose post Slack refused, so it
  can be tried again.
  """
  def release_reply(%Item{id: item_id}) do
    {_released, _rows} = Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [reply_posted_by_id: nil])
    :ok
  end
end

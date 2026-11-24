defmodule Rail.Users.Actions.ListInvites do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite

  @doc "The invites nobody has used yet, newest first. An accepted one is a user now, and the Users list shows them."
  def list_invites(_scope) do
    query =
      from i in Invite,
        where: is_nil(i.accepted_at),
        order_by: [desc: i.inserted_at],
        preload: [:invited_by]

    {:ok, Repo.all(query)}
  end
end

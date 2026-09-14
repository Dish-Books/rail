defmodule Rail.Users.Actions.ListInvites do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite

  def list_invites(_scope) do
    query =
      from i in Invite,
        order_by: [asc_nulls_first: i.accepted_at, desc: i.inserted_at],
        preload: [:invited_by, :accepted_user]

    {:ok, Repo.all(query)}
  end
end

defmodule Rail.Pipeline.Utils.UnsentRound do
  @moduledoc """
  The round a run asked that has not gone back to it yet.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Lists `run`'s unsent questions, open, answered or dismissed, in the order they were asked.
  """
  def unsent_round(%Run{id: run_id}) do
    Repo.all(
      from q in Question,
        where: q.run_id == ^run_id and q.status in [:pending, :answered, :dismissed] and is_nil(q.delivered_at),
        order_by: [asc: q.inserted_at, asc: q.id]
    )
  end
end

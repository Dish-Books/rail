defmodule Rail.Learnings.Workers.EmbedPending do
  @moduledoc """
  The hourly sweep that queues an embedding for every live rule without one for the current model,
  so a rule whose job gave up during an outage, or was written before Goth was on, comes back into search.
  """
  use Oban.Worker, queue: :learnings_embed, max_attempts: 1, unique: [period: 3_000]

  import Ecto.Query
  import Rail.Learnings.Utils.EnqueueEmbedding

  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # With Goth off every job would only cancel itself, an hour of noise at a time.
    if Rail.goth_enabled?() do
      model = Vertex.model()

      from(l in Learning,
        where: l.status in [:proposed, :provisional, :active],
        where: is_nil(l.embedding) or is_nil(l.embedding_model) or l.embedding_model != ^model
      )
      |> Repo.all()
      |> enqueue_embedding()
    end

    :ok
  end
end

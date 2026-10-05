defmodule Rail.Learnings.Actions.EmbedLearning do
  @moduledoc """
  Writes a rule's embedding unless it has one for its text and model, and only if the text is still what was embedded.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged

  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Repo

  @doc """
  Embeds `learning` as it now stands in the database. Returns `{:ok, learning}`.
  """
  def embed_learning(%Learning{id: id}) do
    case Repo.get(Learning, id) do
      %Learning{embedding: %Pgvector{}, embedding_model: model} = learning when is_binary(model) ->
        if model == Vertex.model(), do: {:ok, learning}, else: embed(learning)

      %Learning{} = learning ->
        embed(learning)

      nil ->
        {:error, :not_found}
    end
  end

  defp embed(%Learning{id: id} = learning) do
    with {:ok, values} <- Vertex.embed(Learning.embedding_text(learning), "RETRIEVAL_DOCUMENT") do
      why = if learning.why, do: dynamic([l], l.why == ^learning.why), else: dynamic([l], is_nil(l.why))

      {written, _rows} =
        Repo.update_all(
          from(l in Learning, where: l.id == ^id and l.rule == ^learning.rule, where: ^why),
          set: [embedding: Pgvector.new(values), embedding_model: Vertex.model()]
        )

      if written == 1, do: broadcast_learnings_changed(learning.project_id)
      {:ok, Repo.get!(Learning, id)}
    end
  end
end

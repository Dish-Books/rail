defmodule Rail.Learnings.Utils.EnqueueEmbedding do
  @moduledoc """
  Queues the embedding of rules whose text was just written.
  """

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Workers.EmbedLearning

  @doc """
  Inserts an `EmbedLearning` job for each of `learnings`. Inside a transaction,
  the jobs commit with the rows.
  """
  def enqueue_embedding(learnings) when is_list(learnings) do
    Enum.each(learnings, fn %Learning{id: id} -> %{learning_id: id} |> EmbedLearning.new() |> Oban.insert!() end)
  end
end

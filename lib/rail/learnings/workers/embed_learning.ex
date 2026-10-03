defmodule Rail.Learnings.Workers.EmbedLearning do
  @moduledoc """
  Embeds one rule after its text is written, unique only while waiting so an edit made mid-run gets a job of its own.
  """
  use Oban.Worker,
    queue: :learnings,
    max_attempts: 5,
    unique: [keys: [:learning_id], states: [:available, :scheduled, :retryable]]

  alias Rail.Learnings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"learning_id" => learning_id}}) do
    with {:ok, learning} <- Learnings.get_learning(learning_id),
         {:ok, _embedded} <- Learnings.embed_learning(learning) do
      :ok
    else
      {:error, :not_found} -> :ok
      # Retrying cannot help a node that has no way to reach Google.
      {:error, :goth_disabled} -> {:cancel, :goth_disabled}
      {:error, reason} -> {:error, reason}
    end
  end
end

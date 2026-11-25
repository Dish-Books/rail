defmodule Rail.Pipeline.Workers.TimeOutCoderabbitReview do
  @moduledoc """
  Gives up on a CodeRabbit review that has not answered in time, so its task's Review is not held by it forever and
  someone can ask again.
  """
  use Oban.Worker, queue: :issues, max_attempts: 3, unique: [period: :infinity]

  alias Rail.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"review_id" => review_id}}) do
    Pipeline.time_out_coderabbit_review(review_id)
    :ok
  end
end

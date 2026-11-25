defmodule Rail.Pipeline.Actions.TimeOutCoderabbitReview do
  @moduledoc """
  Ends a CodeRabbit review that never answered, so the Review it holds can finish and someone can ask again.
  """

  import Rail.Pipeline.Utils.FinishCoderabbitReview

  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Repo

  @doc """
  Times out the review with id `review_id` if it is still waiting. Returns `{:ok, review}`, `{:ok, :already_finished}`
  for one that answered, or `{:error, :not_found}` for one deleted with its task.
  """
  def time_out_coderabbit_review(review_id) when is_binary(review_id) do
    case Repo.get(CoderabbitReview, review_id) do
      %CoderabbitReview{} = review -> finish_coderabbit_review(review, :timed_out, %{}, nil)
      nil -> {:error, :not_found}
    end
  end
end

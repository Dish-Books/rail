defmodule Rail.Pipeline.Actions.ReadReview do
  @moduledoc """
  Reads whether a review pass was closed, from the `{saved_at}` file `save_review`
  writes; an old-brief agent's report there is not a closed review.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns when `task`'s review was closed, or `nil` when it has not been.

  Anything but the shape `save_review` writes is not closed. Requires `issue` to
  be preloaded.
  """
  def read_review(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "reviews", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"saved_at" => saved_at} = review} when map_size(review) == 1 and is_binary(saved_at) <-
           Jason.decode(content),
         {:ok, closed_at, _offset} <- DateTime.from_iso8601(saved_at) do
      closed_at
    else
      _not_closed -> nil
    end
  end
end

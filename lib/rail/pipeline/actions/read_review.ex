defmodule Rail.Pipeline.Actions.ReadReview do
  @moduledoc """
  Reads whether a review pass has been closed, out of its task's scratch directory.

  `save_review` writes `<scratch>/reviews/<identifier>.json` once a pass is
  finished; the findings themselves are rows. A report an agent wrote there
  before Rail took over the file still counts, so a review in flight then stays
  closed.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns when `task`'s review was closed, or `nil` when it has not been.

  A file that is missing or does not decode is not closed. Requires `issue` to
  be preloaded.
  """
  def read_review(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "reviews", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{} = review} <- Jason.decode(content),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      saved_at(review["saved_at"]) || DateTime.from_unix!(mtime)
    else
      _unreadable -> nil
    end
  end

  defp saved_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, saved_at, _offset} -> saved_at
      {:error, _not_a_time} -> nil
    end
  end

  defp saved_at(_older_report), do: nil
end

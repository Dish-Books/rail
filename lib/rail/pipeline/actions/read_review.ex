defmodule Rail.Pipeline.Actions.ReadReview do
  @moduledoc """
  Reads the finished passes of a task's Review from the `{passes}` file `save_review` writes. The number of
  passes is what numbers the rounds, and anything but that shape is no pass at all.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `task`'s finished passes, oldest first, each `%{round:, saved_at:, head:, finished_at:}`; `head` is
  the commit the pass read and `finished_at` when the review was finished on it. Requires `issue` loaded.
  """
  def read_review(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    with {:ok, content} <- File.read(Path.join([scratch_path, "reviews", "#{identifier}.json"])),
         {:ok, %{"passes" => passes}} when is_list(passes) <- Jason.decode(content),
         [_first | _rest] = read <- Enum.map(passes, &pass/1),
         false <- Enum.member?(read, nil) do
      read
    else
      _no_pass -> []
    end
  end

  defp pass(%{"round" => round, "saved_at" => saved_at} = pass) when is_integer(round) and is_binary(saved_at) do
    case DateTime.from_iso8601(saved_at) do
      {:ok, saved_at, _offset} ->
        %{round: round, saved_at: saved_at, head: head(pass["head"]), finished_at: finished_at(pass["finished_at"])}

      _unreadable ->
        nil
    end
  end

  defp pass(_other), do: nil

  defp head(head) when is_binary(head), do: head
  defp head(_none), do: nil

  defp finished_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, finished_at, _offset} -> finished_at
      _unreadable -> nil
    end
  end

  defp finished_at(_never), do: nil
end

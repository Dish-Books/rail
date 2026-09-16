defmodule Rail.Pipeline.Actions.ReadReview do
  @moduledoc """
  Reads the findings a review run wrote into its task's scratch directory.

  The reviewer owns `<scratch>/reviews/<identifier>.json` and rewrites the whole
  of it every pass. What comes out of it is the agent's word, not Rail's, so a
  finding missing a key, a title or a severity Rail knows is no finding rather
  than a crash.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc """
  Returns the findings `task`'s review run wrote, or `nil` when there are none to
  read.

  A file that is missing, blank or not the shape agreed is `nil`; an empty list
  is a review that found nothing, which is a different thing. Requires `issue` to
  be preloaded.
  """
  def read_review(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "reviews", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"findings" => findings}} when is_list(findings) <- Jason.decode(content) do
      findings |> Enum.filter(&finding?/1) |> Enum.map(&finding/1)
    else
      _unreadable -> nil
    end
  end

  defp finding?(%{"key" => key, "title" => title} = finding) when is_binary(key) and is_binary(title) do
    Regex.match?(@key, key) and String.trim(title) != "" and
      enum(finding["severity"], ReviewFinding.severities()) != nil and
      enum(finding["recommendation"], ReviewFinding.recommendations()) != nil
  end

  defp finding?(_malformed), do: false

  defp finding(%{"key" => key, "title" => title} = finding) do
    %{
      key: key,
      title: String.trim(title),
      detail: text(finding["detail"]),
      file: text(finding["file"]),
      line: line(finding["line"]),
      severity: enum(finding["severity"], ReviewFinding.severities()),
      recommendation: enum(finding["recommendation"], ReviewFinding.recommendations()),
      status: enum(finding["status"], ReviewFinding.statuses()) || :open
    }
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_missing), do: nil

  defp line(value) when is_integer(value) and value > 0, do: value

  defp line(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> parsed
      _not_a_line -> nil
    end
  end

  defp line(_missing), do: nil

  defp enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn candidate -> Atom.to_string(candidate) == String.trim(value) end)
  end

  defp enum(_missing, _allowed), do: nil
end

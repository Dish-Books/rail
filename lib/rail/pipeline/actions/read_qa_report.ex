defmodule Rail.Pipeline.Actions.ReadQaReport do
  @moduledoc """
  Reads the verdict a QA pass saved out of its task's scratch directory,
  `<scratch>/qa/<identifier>.json`.

  Only the shape `save_verdict` writes counts: an old-brief agent's report there,
  findings and all, is no verdict, so its run does not pass as finished.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  @saved ["verdict", "summary", "not_checked"]

  @doc """
  Returns `task`'s QA verdict, or `nil` when there is none to read.

  Requires `issue` to be preloaded.
  """
  def read_qa_report(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "qa", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"verdict" => _verdict} = report} <- Jason.decode(content),
         [] <- Map.keys(report) -- @saved do
      %QaReport{
        verdict: enum(report["verdict"], QaReport.verdicts()),
        summary: text(report["summary"]),
        not_checked: text(report["not_checked"])
      }
    else
      _unreadable -> nil
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_missing), do: nil

  defp enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn candidate -> Atom.to_string(candidate) == String.trim(value) end)
  end

  defp enum(_missing, _allowed), do: nil
end

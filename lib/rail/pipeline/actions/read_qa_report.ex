defmodule Rail.Pipeline.Actions.ReadQaReport do
  @moduledoc """
  Reads the report a QA run wrote into its task's scratch directory.

  QA owns `<scratch>/qa/<identifier>.json` and rewrites the whole of it every
  pass. What comes out of it is the agent's word, not Rail's, so a finding
  missing a key, a title, the check it came from or a severity Rail knows is no
  finding rather than a crash. Evidence Rail cannot show is left out of the
  finding and named in its `refused`, so a report can be sent back saying why.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc """
  Returns the report `task`'s QA run wrote, or `nil` when there is none to read.

  A file that is missing, blank or not the shape agreed is `nil`; a report with
  an empty finding list is a QA pass that found nothing, which is a different
  thing. Requires `issue` to be preloaded.
  """
  def read_qa_report(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    qa_dir = Path.join(scratch_path, "qa")
    path = Path.join(qa_dir, "#{identifier}.json")

    with {:ok, content} <- File.read(path),
         {:ok, %{"findings" => findings} = report} when is_list(findings) <- Jason.decode(content) do
      %QaReport{
        verdict: enum(report["verdict"], QaReport.verdicts()),
        summary: text(report["summary"]),
        not_checked: text(report["not_checked"]),
        findings: findings |> Enum.filter(&finding?/1) |> Enum.map(&finding(&1, qa_dir))
      }
    else
      _unreadable -> nil
    end
  end

  defp finding?(%{"key" => key, "title" => title, "check" => check} = finding)
       when is_binary(key) and is_binary(title) and is_binary(check) do
    Regex.match?(@key, key) and String.trim(title) != "" and String.trim(check) != "" and
      enum(finding["severity"], QaFinding.severities()) != nil and
      enum(finding["recommendation"], QaFinding.recommendations()) != nil
  end

  defp finding?(_malformed), do: false

  defp finding(%{"key" => key, "title" => title, "check" => check} = finding, qa_dir) do
    {evidence, refused} = evidence(finding["evidence"], qa_dir)

    %{
      key: key,
      title: String.trim(title),
      check: String.trim(check),
      criterion: text(finding["criterion"]),
      screen: text(finding["screen"]),
      steps: text(finding["steps"]),
      expected: text(finding["expected"]),
      observed: text(finding["observed"]),
      detail: text(finding["detail"]),
      suggestion: text(finding["suggestion"]),
      severity: enum(finding["severity"], QaFinding.severities()),
      recommendation: enum(finding["recommendation"], QaFinding.recommendations()),
      status: enum(finding["status"], QaFinding.statuses()) || :open,
      caused_by_change: caused_by_change(finding["caused_by_change"]),
      evidence: evidence,
      refused: refused
    }
  end

  defp evidence(entries, qa_dir) when is_list(entries) do
    read = Enum.map(entries, &one_evidence(&1, qa_dir))

    {read |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1), Enum.flat_map(read, &elem(&1, 1))}
  end

  defp evidence(_missing, _qa_dir), do: {[], []}

  # A path that is not confined to the QA directory is the one thing here that
  # would reach the filesystem on a stranger's request, so it is refused at the
  # door as well as in the changeset behind it.
  defp one_evidence(%{"name" => name} = entry, qa_dir) when is_binary(name) do
    name = text(name)
    kind = enum(entry["kind"], QaEvidence.kinds())
    path = text(entry["path"])
    shown = text(entry["text"])

    path_refused =
      cond do
        path == nil -> nil
        not QaEvidence.confined?(path) -> "#{path} is outside the QA folder"
        not File.regular?(Path.join(qa_dir, path)) -> "#{path} is not a file in the QA folder"
        true -> nil
      end

    kept_path = if path_refused == nil, do: path

    cond do
      name == nil or kind == nil -> {nil, ["an entry with no name or kind"]}
      kept_path || shown -> {%{name: name, kind: kind, path: kept_path, text: shown}, List.wrap(path_refused)}
      path_refused -> {nil, [path_refused]}
      true -> {nil, ["#{name} has no file and no text"]}
    end
  end

  defp one_evidence(_malformed, _qa_dir), do: {nil, ["an entry with no name or kind"]}

  defp caused_by_change(value) when is_boolean(value), do: value
  defp caused_by_change(_missing), do: true

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

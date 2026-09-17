defmodule Rail.Pipeline.Actions.ReadQaReport do
  @moduledoc """
  Reads the report a QA run wrote into its task's scratch directory.

  QA owns `<scratch>/qa/<identifier>.json` and rewrites the whole of it every
  pass. What comes out of it is the agent's word, not Rail's, so a finding
  missing a key, a title, the check it came from or a severity Rail knows is no
  finding rather than a crash, and a piece of evidence naming a path that climbs
  out of the QA directory is dropped while its finding survives without it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9][a-z0-9-]*\z/
  @path ~r{\A[A-Za-z0-9._][A-Za-z0-9._/-]*\z}

  @doc """
  Returns the report `task`'s QA run wrote, or `nil` when there is none to read.

  A file that is missing, blank or not the shape agreed is `nil`; a report with
  an empty finding list is a QA pass that found nothing, which is a different
  thing. Requires `issue` to be preloaded.
  """
  def read_qa_report(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "qa", "#{identifier}.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"findings" => findings} = report} when is_list(findings) <- Jason.decode(content) do
      %QaReport{
        verdict: enum(report["verdict"], QaReport.verdicts()),
        summary: text(report["summary"]),
        not_checked: text(report["not_checked"]),
        findings: findings |> Enum.filter(&finding?/1) |> Enum.map(&finding/1)
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

  defp finding(%{"key" => key, "title" => title, "check" => check} = finding) do
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
      evidence: evidence(finding["evidence"])
    }
  end

  defp evidence(entries) when is_list(entries) do
    entries |> Enum.filter(&evidence?/1) |> Enum.map(&one_evidence/1)
  end

  defp evidence(_missing), do: []

  # A path that is not confined to the QA directory is the one thing here that
  # would reach the filesystem on a stranger's request, so it is refused at the
  # door as well as in the changeset behind it.
  defp evidence?(%{"name" => name} = entry) when is_binary(name) do
    String.trim(name) != "" and enum(entry["kind"], QaEvidence.kinds()) != nil and
      (confined?(entry["path"]) or text(entry["text"]) != nil)
  end

  defp evidence?(_malformed), do: false

  defp one_evidence(%{"name" => name} = entry) do
    %{
      name: String.trim(name),
      kind: enum(entry["kind"], QaEvidence.kinds()),
      path: if(confined?(entry["path"]), do: String.trim(entry["path"])),
      text: text(entry["text"])
    }
  end

  defp confined?(path) when is_binary(path) do
    trimmed = String.trim(path)

    Regex.match?(@path, trimmed) and ".." not in Path.split(trimmed)
  end

  defp confined?(_missing), do: false

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

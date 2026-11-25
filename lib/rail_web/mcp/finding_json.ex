defmodule RailWeb.Mcp.FindingJSON do
  @moduledoc false

  use RailWeb, :verified_routes

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Task

  @doc "A task's findings, from one read of the round and the findings, so every version names the round they came from."
  def index(%{issue: issue, task: task, round: round, findings: findings, logins: logins}) do
    %{
      identifier: issue.identifier,
      stage: Task.stage_label(task),
      findings: Enum.map(findings, &finding(&1, task, round, logins))
    }
  end

  @doc "One finding, from the same read as `round`, so its filed issue is loaded and its version is consistent."
  def show(%{task: task, round: round, finding: finding, logins: logins}),
    do: %{finding: finding(finding, task, round, logins)}

  defp finding(%Finding{} = finding, %Task{} = task, round, logins) do
    %{
      key: finding.key,
      # The round read and the row's last change, so decide_finding refuses a ruling either has moved past.
      version: "#{round}@#{DateTime.to_iso8601(finding.updated_at)}",
      title: finding.title,
      kind: finding.kind,
      severity: finding.severity,
      round: finding.carried_round || finding.round,
      status: finding.status,
      suppressed: Finding.suppressed?(finding),
      where: Finding.where(finding),
      steps: finding.steps,
      places: Enum.map(finding.places, &FindingPlace.describe/1),
      problem: finding.problem,
      fix: finding.fix,
      rule: finding.rule,
      recommendation: %{decision: word(finding.recommendation), why: finding.why},
      ruling: ruling(finding, logins),
      filed_as: finding.issue && finding.issue.identifier,
      evidence: finding.evidence |> Enum.with_index() |> Enum.map(&evidence(&1, finding, task)),
      history: Enum.map(finding.notes, &note(&1, logins))
    }
  end

  defp ruling(%Finding{decision: nil}, _logins), do: nil
  defp ruling(%Finding{} = finding, logins), do: %{decision: word(finding.decision), by: logins[finding.decided_by_id]}

  # A code range reads as a place does, `file:line-end`.
  defp evidence({%FindingEvidence{kind: :code} = piece, _index}, _finding, _task) do
    where = FindingPlace.describe(%FindingPlace{file: piece.file, line: piece.line, end_line: piece.end_line})
    %{name: piece.name, kind: :code, where: where}
  end

  defp evidence({%FindingEvidence{} = piece, index}, %Finding{key: key}, %Task{} = task) do
    url = if is_binary(piece.path), do: url(~p"/tasks/#{task.id}/findings/#{key}/evidence/#{index}")
    %{name: piece.name, kind: piece.kind, text: piece.text, url: url, commit: piece.commit, taken_at: piece.taken_at}
  end

  defp note(%FindingNote{} = note, logins) do
    %{
      round: note.round,
      kind: note.kind,
      at: note.at,
      by: note.by_id && logins[note.by_id],
      decision: note.decision && word(note.decision),
      status: note.status,
      text: note.text
    }
  end

  defp word(:fix), do: "fix"
  defp word(:skip), do: "dont_fix"
  defp word(:new_issue), do: "new_issue"
end

defmodule Rail.Pipeline.Utils.FormatFindings do
  @moduledoc false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Task

  @doc """
  The findings already on `task` as a brief's section, newest round first, with what the human ruled and what has
  happened to each, so no agent has to remember them. Empty when there are none.
  """
  def format_findings(%Task{} = task) do
    case Pipeline.list_findings(task) do
      [] ->
        ""

      findings ->
        """
        These findings are already on the task, newest round first, with what the human ruled and what has happened to each.

        #{Enum.map_join(findings, "\n", &finding_lines/1)}
        """
    end
  end

  defp finding_lines(%Finding{} = finding) do
    round = if finding.carried_round, do: "carried into round #{finding.carried_round}", else: "round #{finding.round}"
    fixed = if finding.fixed_in, do: ", fixed in #{String.slice(finding.fixed_in, 0, 7)}", else: ""

    head =
      "- `#{finding.key}` [#{round}, #{finding.severity} #{finding.kind}, human ruled: #{ruling(finding)}, " <>
        "status: #{finding.status}#{fixed}] #{finding.title} (#{Finding.where(finding)})"

    places = finding.places |> Enum.with_index(1) |> Enum.map(fn {place, n} -> "  Place #{n}: #{place_line(place)}" end)
    notes = Enum.map(finding.notes, &"  #{note_line(&1)}")

    Enum.join([head | rule_line(finding) ++ places ++ notes], "\n")
  end

  defp rule_line(%Finding{rule: rule}) when is_binary(rule), do: ["  Rule: #{rule}"]
  defp rule_line(%Finding{}), do: []

  defp place_line(%FindingPlace{label: label} = place) when is_binary(label),
    do: "#{FindingPlace.describe(place)}, #{label}"

  defp place_line(%FindingPlace{} = place), do: FindingPlace.describe(place)

  defp note_line(%FindingNote{} = note) do
    words = if note.text, do: ": #{note.text}", else: ""
    commit = if note.commit, do: " on #{String.slice(note.commit, 0, 7)}", else: ""
    "Round #{note.round}, #{note_kind(note)}#{commit}#{words}"
  end

  defp note_kind(%FindingNote{kind: :ruling, decision: decision}), do: "ruled #{ruling_word(decision)}"
  defp note_kind(%FindingNote{kind: :pass, status: status}) when is_atom(status) and status != nil, do: "#{status}"
  defp note_kind(%FindingNote{kind: :fix}), do: "fixed"
  defp note_kind(%FindingNote{kind: kind}), do: to_string(kind)

  defp ruling(%Finding{decision: decision}), do: ruling_word(decision)

  defp ruling_word(:fix), do: "Fix"
  defp ruling_word(:skip), do: "Don't fix"
  defp ruling_word(nil), do: "not yet"
end

defmodule Rail.Pipeline.Actions.ParseStageVerdict do
  @moduledoc """
  Reads a gate run's verdict out of its own log.
  """

  import Rail.Runs.Utils.AssistantLog

  alias Rail.Domain.StageVerdict

  @prefixed_pattern ~r/^verdict\s*[:\-]?\s*(approved|changes\s+requested|pass(?:ed)?|fail(?:ed)?)(.*)$/i
  @bare_pattern ~r/^(approved|changes\s+requested|pass(?:ed)?|fail(?:ed)?)\s*(?:[-–—:,.(](.*))?$/i

  @word_verdicts %{
    "approved" => :passed,
    "pass" => :passed,
    "passed" => :passed,
    "changes requested" => :changes_requested,
    "fail" => :changes_requested,
    "failed" => :changes_requested
  }

  @doc """
  Returns the `%StageVerdict{}` the run last stated.

  The whole log is read, and the last verdict line in it wins. That makes a
  verdict survive anything said after it — chatting with a reviewer that has
  already passed does not undo the pass — while still letting the agent state a
  new one explicitly. The words also appear inside findings themselves ("this
  check passed", "APPROVED once the leak is fixed"), which is the other reason
  the last line is the one that counts. Table rows are skipped.
  """
  def parse_stage_verdict(run_or_id) do
    {verdict, explanation} =
      run_or_id
      |> assistant_log()
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.reduce({:unclear, nil}, fn raw_line, acc ->
        line = strip_markdown(raw_line)

        if line == "" or String.starts_with?(line, "|") do
          acc
        else
          match_verdict_line(line, acc)
        end
      end)

    %StageVerdict{verdict: verdict, status: verdict, explanation: explanation}
  end

  defp match_verdict_line(line, {current_verdict, current_explanation} = acc) do
    cond do
      Regex.match?(@prefixed_pattern, line) ->
        [_match, word, rest] = Regex.run(@prefixed_pattern, line)
        normalize_matched_verdict(word, rest, current_verdict, current_explanation)

      Regex.match?(@bare_pattern, line) ->
        case Regex.run(@bare_pattern, line) do
          [_match, word, rest] -> normalize_matched_verdict(word, rest, current_verdict, current_explanation)
          [_match, word] -> normalize_matched_verdict(word, "", current_verdict, current_explanation)
        end

      true ->
        acc
    end
  end

  defp normalize_matched_verdict(word, raw_rest, current_verdict, current_explanation) do
    normalized_word =
      word
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    verdict = Map.get(@word_verdicts, normalized_word, current_verdict)
    explanation = clean_explanation(raw_rest)

    {verdict, explanation || current_explanation}
  end

  defp clean_explanation(raw_rest) do
    cleaned =
      raw_rest
      |> String.replace(~r/^[\s\-–—:,.\)]+/, "")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp strip_markdown(line) do
    line
    |> String.replace(~r/[*_`]/, "")
    |> String.replace(~r/^[\s>#]*(?:[-+]\s+)?/, "")
    |> String.trim()
  end
end

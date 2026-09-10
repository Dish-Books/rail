defmodule Rail.Domain.StageVerdict do
  @moduledoc """
  What a Reviewer or QA run concluded about the change it looked at.

  Inspects CLI role stdout / output for `VERDICT:` lines.
  Matches:
    - `:passed`: `VERDICT: APPROVED`, `VERDICT: PASS`, `VERDICT: PASSED`
    - `:changes_requested`: `VERDICT: CHANGES REQUESTED`, `VERDICT: FAIL`, `VERDICT: FAILED`
    - `:unclear`: Any other output, missing verdict, or ambiguous output.

  Captures any trailing or associated explanation/reasoning.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @verdicts [:passed, :changes_requested, :unclear]

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

  @primary_key false
  embedded_schema do
    field :verdict, Ecto.Enum, values: @verdicts, default: :unclear
    field :status, Ecto.Enum, values: @verdicts, default: :unclear
    field :explanation, :string
  end

  @fields [:verdict, :status, :explanation]

  @doc "Builds a changeset for a stage verdict."
  def changeset(stage_verdict, attrs) do
    stage_verdict
    |> cast(attrs, @fields)
    |> validate_required([:verdict])
  end

  @doc """
  Reads the verdict out of a role's final stdout or report text.

  The last verdict line wins, since the verdict is the last thing written
  and the words appear earlier in the findings themselves ("this check passed",
  "APPROVED once the leak is fixed"). Table rows (starting with `|`) are skipped.
  """
  def parse(nil), do: %__MODULE__{verdict: :unclear, status: :unclear, explanation: nil}

  def parse(output) when is_binary(output) do
    normalized = String.replace(output, "\r\n", "\n")
    lines = String.split(normalized, "\n")

    {final_verdict, final_explanation} =
      Enum.reduce(lines, {:unclear, nil}, fn raw_line, {current_verdict, current_explanation} ->
        line = strip_markdown(raw_line)

        if line == "" or String.starts_with?(line, "|") do
          {current_verdict, current_explanation}
        else
          match_verdict_line(line, current_verdict, current_explanation)
        end
      end)

    %__MODULE__{
      verdict: final_verdict,
      status: final_verdict,
      explanation: final_explanation
    }
  end

  @doc "Returns true if the verdict is `:passed`."
  def passed?(%__MODULE__{verdict: :passed}), do: true
  def passed?(:passed), do: true
  def passed?(output) when is_binary(output), do: parse(output).verdict == :passed
  def passed?(_other), do: false

  @doc "Returns true if the verdict is `:changes_requested`."
  def changes_requested?(%__MODULE__{verdict: :changes_requested}), do: true
  def changes_requested?(:changes_requested), do: true
  def changes_requested?(output) when is_binary(output), do: parse(output).verdict == :changes_requested
  def changes_requested?(_other), do: false

  @doc "Returns true if the verdict is `:unclear`."
  def unclear?(%__MODULE__{verdict: :unclear}), do: true
  def unclear?(:unclear), do: true
  def unclear?(output) when is_binary(output), do: parse(output).verdict == :unclear
  def unclear?(_other), do: false

  @doc """
  Formats a `StageVerdict` struct or `(verdict, explanation)` to string.
  """
  def format(%__MODULE__{verdict: verdict, explanation: explanation}) do
    format(verdict, explanation)
  end

  def format(verdict, explanation \\ nil) do
    keyword =
      case verdict do
        :passed -> "APPROVED"
        :changes_requested -> "CHANGES REQUESTED"
        :unclear -> "UNCLEAR"
      end

    if is_binary(explanation) and String.trim(explanation) != "" do
      "VERDICT: #{keyword} - #{String.trim(explanation)}"
    else
      "VERDICT: #{keyword}"
    end
  end

  defp match_verdict_line(line, current_verdict, current_explanation) do
    cond do
      Regex.match?(@prefixed_pattern, line) ->
        [_match, word, rest] = Regex.run(@prefixed_pattern, line)
        normalize_matched_verdict(word, rest, current_verdict, current_explanation)

      Regex.match?(@bare_pattern, line) ->
        case Regex.run(@bare_pattern, line) do
          [_match, word, rest] ->
            normalize_matched_verdict(word, rest, current_verdict, current_explanation)

          [_match, word] ->
            normalize_matched_verdict(word, "", current_verdict, current_explanation)
        end

      true ->
        {current_verdict, current_explanation}
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

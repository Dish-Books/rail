defmodule Rail.Pipeline.Utils.DetectQuestions do
  @moduledoc """
  Detects question markers emitted in agent prose: `[QUESTION: ...] [OPTIONS: ...]`.

  Matches lines that open with `[QUESTION: ...]` (optionally prefixed with whitespace,
  blockquotes `>`, or list bullets `*`, `-`). Extracts comma-separated options when present.
  Rejects placeholder prompts that echo role briefs or ellipses.
  """

  alias Rail.Pipeline.DetectedQuestion

  @question_regex ~r/^[\s>*\-]*\[QUESTION:\s*([^\]]+)\]/i
  @options_regex ~r/\[OPTIONS:\s*([^\]]+)\]/i
  @placeholder_tag_regex ~r/^<[^>]*>$/
  @placeholder_dots_regex ~r/[.\x{2026}\s]/u

  @doc """
  Detects every agent question marker in `text`.

  Returns a list of `%Rail.Pipeline.DetectedQuestion{}` in the order they appear, with
  repeats of the same prompt collapsed. An agent that asks several things in one
  turn gets all of them through; placeholder prompts are dropped.
  """
  def detect_questions(nil), do: []

  def detect_questions(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(fn line ->
      with [_full_match, raw_prompt] <- Regex.run(@question_regex, line),
           prompt = String.trim(raw_prompt),
           false <- placeholder?(prompt) do
        [%DetectedQuestion{prompt: prompt, options: parse_options(line)}]
      else
        _no_question -> []
      end
    end)
    |> Enum.uniq_by(&(&1.prompt |> String.trim() |> String.downcase()))
  end

  defp placeholder?(prompt) do
    prompt == "" or Regex.match?(@placeholder_tag_regex, prompt) or
      String.replace(prompt, @placeholder_dots_regex, "") == ""
  end

  defp parse_options(line) do
    case Regex.run(@options_regex, line) do
      [_full_match, raw_options] ->
        raw_options
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end
end

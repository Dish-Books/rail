defmodule Rail.Runs.QuestionDetector do
  @moduledoc """
  Detects question markers emitted in agent prose: `[QUESTION: ...] [OPTIONS: ...]`.

  Matches lines that open with `[QUESTION: ...]` (optionally prefixed with whitespace,
  blockquotes `>`, or list bullets `*`, `-`). Extracts comma-separated options when present.
  Rejects placeholder prompts that echo role briefs or ellipses.
  """

  @enforce_keys [:prompt]
  defstruct [
    :id,
    :prompt,
    :task_id,
    :role_id,
    :context_summary,
    options: []
  ]

  @question_regex ~r/^[\s>*\-]*\[QUESTION:\s*([^\]]+)\]/i
  @options_regex ~r/\[OPTIONS:\s*([^\]]+)\]/i
  @placeholder_tag_regex ~r/^<[^>]*>$/
  @placeholder_dots_regex ~r/[.\x{2026}\s]/u

  @doc """
  Detects whether `line_or_text` contains an agent question marker.

  Returns a `%Rail.Runs.QuestionDetector{}` struct or `nil` if no question is present
  or if the prompt is a placeholder.
  """
  def detect_question(line_or_text, opts \\ [])

  def detect_question(nil, _opts), do: nil

  def detect_question(text, opts) when is_binary(text) and is_list(opts) do
    detect_question(text, Map.new(opts))
  end

  def detect_question(text, opts) when is_binary(text) and is_map(opts) do
    if String.contains?(text, "\n") do
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.find_value(&detect_single_line(&1, opts))
    else
      detect_single_line(text, opts)
    end
  end

  defp detect_single_line(line, opts) do
    case Regex.run(@question_regex, line) do
      [_full_match, raw_prompt] ->
        prompt = String.trim(raw_prompt)

        if placeholder?(prompt) do
          nil
        else
          build_question(prompt, line, opts)
        end

      nil ->
        nil
    end
  end

  defp placeholder?(prompt) do
    cond do
      prompt == "" ->
        true

      Regex.match?(@placeholder_tag_regex, prompt) ->
        true

      String.replace(prompt, @placeholder_dots_regex, "") == "" ->
        true

      true ->
        false
    end
  end

  defp build_question(prompt, line, opts) do
    options = parse_options(line)
    task_id = extract_task_id(opts)
    role_id = extract_role_id(opts)
    context_summary = extract_context_summary(opts)

    id =
      opts[:id] ||
        "q-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    %__MODULE__{
      id: id,
      prompt: prompt,
      options: options,
      task_id: task_id,
      role_id: role_id,
      context_summary: context_summary
    }
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

  defp extract_task_id(opts) do
    cond do
      is_binary(opts[:task_id]) -> opts[:task_id]
      is_map(opts[:task]) and is_binary(Map.get(opts[:task], :id)) -> Map.get(opts[:task], :id)
      true -> nil
    end
  end

  defp extract_role_id(opts) do
    cond do
      is_binary(opts[:role_id]) -> opts[:role_id]
      is_map(opts[:role]) and is_binary(Map.get(opts[:role], :id)) -> Map.get(opts[:role], :id)
      true -> nil
    end
  end

  defp extract_context_summary(opts) do
    cond do
      is_binary(opts[:context_summary]) ->
        opts[:context_summary]

      is_binary(opts[:task_title]) ->
        "Asked during: #{opts[:task_title]}"

      is_map(opts[:task]) and is_binary(Map.get(opts[:task], :title)) ->
        "Asked during: #{Map.get(opts[:task], :title)}"

      true ->
        nil
    end
  end
end

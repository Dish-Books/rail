defmodule Rail.Runs.Actions.BuildPrompt do
  @moduledoc false

  alias Rail.Backends.Schemas.Backend

  @doc """
  Constructs the agent prompt string passed via `-p`.

  Handles:
  - System prompt split: Claude receives role instructions via `--system-prompt`
    (omitted from the prompt body), while Agy receives `<role-instructions>...</role-instructions>`
    on the first turn only - a resumed conversation already carries them, so re-sending
    would stack a copy into the transcript every turn.
  - Resume turns with an answer: sends only the answer + "Continue from where you stopped.",
    omitting the ticket, context snippet, and plan so the agent does not ask again.
  - Initial turns and non-resumed answer turns: includes context snippet, ticket body,
    optional plan, and optional pending answer.
  """
  def build_prompt(opts) when is_list(opts) do
    build_prompt(Map.new(opts))
  end

  def build_prompt(opts) when is_map(opts) do
    answer = opts[:pending_answer] || opts[:answer]
    has_answer = is_binary(answer) and String.trim(answer) != ""

    role_instructions =
      if claude?(opts[:backend]) do
        nil
      else
        opts[:role_instructions] || opts[:system_prompt]
      end

    if has_answer do
      "#{answer}\n\nContinue from where you stopped.\n"
    else
      role_instructions
      |> role_instructions_block()
      |> maybe_append_context_snippet(opts[:context_snippet])
      |> append_ticket(opts)
      |> maybe_append_plan(opts[:plan])
      |> maybe_append_answer(answer, has_answer)
    end
  end

  defp role_instructions_block(instructions) when is_binary(instructions) do
    if String.trim(instructions) == "" do
      ""
    else
      "<role-instructions>\n#{instructions}\n</role-instructions>\n\n"
    end
  end

  defp role_instructions_block(_no_instructions), do: ""

  defp maybe_append_context_snippet(buffer, snippet) when is_binary(snippet) and snippet != "" do
    if String.trim(snippet) == "" do
      buffer
    else
      buffer <> "#{snippet}\n\n"
    end
  end

  defp maybe_append_context_snippet(buffer, _empty_snippet), do: buffer

  defp append_ticket(buffer, opts) do
    ticket_text =
      cond do
        is_binary(opts[:ticket]) -> opts[:ticket]
        is_binary(opts[:task_description]) -> opts[:task_description]
        is_binary(opts[:description]) -> opts[:description]
        is_map(opts[:task]) and is_binary(Map.get(opts[:task], :description)) -> Map.get(opts[:task], :description)
        true -> ""
      end

    buffer <> "#{ticket_text}\n"
  end

  defp maybe_append_plan(buffer, plan) when is_binary(plan) and plan != "" do
    if String.trim(plan) == "" do
      buffer
    else
      buffer <> "\n#{plan}\n"
    end
  end

  defp maybe_append_plan(buffer, _empty_plan), do: buffer

  defp maybe_append_answer(buffer, answer, true), do: buffer <> "\n#{answer}\n"
  defp maybe_append_answer(buffer, _answer, false), do: buffer

  defp claude?(%Backend{name: name}), do: name == :claude
  defp claude?(_other_backend), do: false
end

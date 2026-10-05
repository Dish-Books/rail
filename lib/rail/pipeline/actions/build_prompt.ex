defmodule Rail.Pipeline.Actions.BuildPrompt do
  @moduledoc false

  @doc """
  Constructs the agent prompt string passed via `-p`.

  Handles:
  - System prompt split: role instructions reach Claude via `--append-system-prompt`,
    so they are never part of the prompt body.
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

    if has_answer do
      "#{answer}\n\nContinue from where you stopped.\n"
    else
      ""
      |> maybe_append_context_snippet(opts[:context_snippet])
      |> append_ticket(opts)
      |> maybe_append_plan(opts[:plan])
    end
  end

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
end

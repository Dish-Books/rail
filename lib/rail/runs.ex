defmodule Rail.Runs do
  @moduledoc """
  Context for agent CLI execution, argv/prompt building, and stream event parsing.
  """

  alias Rail.Domain.RunFailure
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.PromptBuilder
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.ToolSummarizer

  defdelegate build_argv(opts), to: ArgvBuilder
  defdelegate build_prompt(opts), to: PromptBuilder
  defdelegate detect_question(line, opts \\ []), to: QuestionDetector
  defdelegate summarize_tool_input(params), to: ToolSummarizer
  defdelegate summarize_tool_input(tool_name, params), to: ToolSummarizer

  @doc """
  Determines whether a failure is transient and retryable.
  """
  def transient?(failure), do: RunFailure.transient?(failure)

  @doc """
  Initializes an event accumulator state struct for either `:claude` or `:agy`.
  """
  def new_event_state(backend, opts \\ [])

  def new_event_state(:claude, opts), do: ClaudeEvents.new(opts)

  def new_event_state(backend, opts) when is_binary(backend) do
    if String.downcase(backend) == "claude" do
      ClaudeEvents.new(opts)
    else
      AgyEvents.new(opts)
    end
  end

  def new_event_state(_other_backend, opts) do
    AgyEvents.new(opts)
  end

  @doc """
  Parses a raw line from an agent NDJSON stdout stream into the accumulator state.
  """
  def parse_line(%ClaudeEvents{} = state, line), do: ClaudeEvents.parse_line(state, line)
  def parse_line(%AgyEvents{} = state, line), do: AgyEvents.parse_line(state, line)

  @doc """
  Dispatches a decoded NDJSON event map to the appropriate backend handler.
  """
  def parse_event(%ClaudeEvents{} = state, event), do: ClaudeEvents.handle_event(state, event)
  def parse_event(%AgyEvents{} = state, event), do: AgyEvents.handle_event(state, event)

  def parse_event(backend, event) when is_atom(backend) or is_binary(backend) do
    state = new_event_state(backend)
    parse_event(state, event)
  end
end

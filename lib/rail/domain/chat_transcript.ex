defmodule Rail.Domain.ChatTranscript do
  @moduledoc """
  Models human-agent conversational turns for chat-enabled roles.

  Parses raw CLI run logs into structured `ChatTurn` blocks, and provides
  markdown and text formatting for role resumption.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Rail.Domain.ChatTurn
  alias Rail.Domain.HandoffLine

  @derive Jason.Encoder

  @human_prefix ~r/^\[human\]\s*/
  @system_prefix ~r/^\[(run|init|tool|tool error|result|rail|handoff|denied|recovered|error|rate limit|stderr|human)(\s|\]|:)/

  @primary_key false
  embedded_schema do
    embeds_many :turns, ChatTurn, on_replace: :delete
    embeds_many :messages, ChatTurn, on_replace: :delete
  end

  @doc "Builds a changeset for a ChatTranscript."
  def changeset(transcript, attrs) do
    transcript
    |> cast(attrs, [])
    |> cast_embed(:turns)
    |> cast_embed(:messages)
    |> sync_messages_and_turns()
  end

  @doc "Returns true if the transcript contains no turns."
  def empty?(%__MODULE__{turns: turns}), do: turns == []
  def empty?(_other), do: true

  @doc "Returns the number of turns in the transcript."
  def count(%__MODULE__{turns: turns}), do: length(turns)

  @doc """
  Parses raw logs (list of log lines or a multiline string) into structured `ChatTurn` blocks.
  """
  def parse(nil), do: %__MODULE__{turns: [], messages: []}
  def parse(""), do: %__MODULE__{turns: [], messages: []}
  def parse([]), do: %__MODULE__{turns: [], messages: []}

  def parse(logs) when is_binary(logs) do
    if String.trim(logs) == "" do
      %__MODULE__{turns: [], messages: []}
    else
      logs
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> parse()
    end
  end

  def parse(logs) when is_list(logs) do
    if Enum.all?(logs, &(String.trim(&1) == "")) do
      %__MODULE__{turns: [], messages: []}
    else
      do_parse(logs)
    end
  end

  @doc "Returns conversational turns (only human/user and agent/role)."
  def conversational_turns(%__MODULE__{turns: turns}) do
    Enum.filter(turns, &(&1.role in [:user, :agent]))
  end

  @doc "Returns user turns."
  def user_turns(%__MODULE__{turns: turns}) do
    Enum.filter(turns, &(&1.role == :user))
  end

  @doc "Returns agent turns."
  def agent_turns(%__MODULE__{turns: turns}) do
    Enum.filter(turns, &(&1.role == :agent))
  end

  @doc """
  Formats the transcript into a human-readable markdown document.
  """
  def to_markdown(%__MODULE__{turns: turns}) do
    Enum.map_join(turns, "\n\n", fn turn ->
      case turn.role do
        :user ->
          "### User\n\n#{turn.content}"

        :agent ->
          "### Assistant\n\n#{turn.content}"

        :system ->
          if turn.author == :activity do
            "```\n#{turn.content}\n```"
          else
            "> #{turn.content}"
          end
      end
    end)
  end

  @doc """
  Formats conversational turns for role resumption prompts.
  Generates `[human] <content>` for user turns, followed by agent responses.
  """
  def format_for_resumption(%__MODULE__{} = transcript) do
    transcript
    |> conversational_turns()
    |> Enum.map_join("\n\n", fn
      %ChatTurn{role: :user, content: content} -> "[human] #{content}"
      %ChatTurn{role: :agent, content: content} -> content
    end)
  end

  defp do_parse(logs) do
    flat_lines =
      Enum.flat_map(logs, fn entry ->
        if String.contains?(entry, "\n") do
          entry |> String.replace("\r\n", "\n") |> String.split("\n")
        else
          [entry]
        end
      end)

    initial_state = %{
      human_lines: nil,
      activity_lines: [],
      role_lines: [],
      pending_handoff: nil,
      pending_handoff_line: nil,
      handoff_note_lines: [],
      turns: []
    }

    final_state = Enum.reduce(flat_lines, initial_state, &process_log_line/2)

    turns =
      final_state
      |> flush_handoff()
      |> flush_human()
      |> flush_activity()
      |> flush_role()
      |> Map.get(:turns, [])
      |> Enum.reverse()

    %__MODULE__{
      turns: turns,
      messages: turns
    }
  end

  defp process_log_line(line, state) do
    is_human = Regex.match?(@human_prefix, line)

    cond do
      is_human ->
        state =
          state
          |> flush_handoff()
          |> flush_activity()
          |> flush_role()

        stripped = Regex.replace(@human_prefix, line, "")
        human_lines = [stripped | state.human_lines || []]
        %{state | human_lines: human_lines}

      state.human_lines != nil ->
        is_system = Regex.match?(@system_prefix, line) or HandoffLine.parse(line) != nil

        if is_system do
          state
          |> flush_human()
          |> process_non_human_line(line)
        else
          %{state | human_lines: [line | state.human_lines]}
        end

      state.pending_handoff != nil ->
        is_system = Regex.match?(@system_prefix, line) or HandoffLine.parse(line) != nil

        if not is_system and not String.starts_with?(line, "[tool") do
          %{state | handoff_note_lines: [line | state.handoff_note_lines]}
        else
          state
          |> flush_handoff()
          |> process_non_human_line(line)
        end

      true ->
        process_non_human_line(state, line)
    end
  end

  defp process_non_human_line(state, line) do
    cond do
      String.starts_with?(line, "[tool ") or String.starts_with?(line, "[tool]") or
          String.starts_with?(line, "[tool error") ->
        state
        |> flush_handoff()
        |> flush_human()
        |> flush_role()
        |> append_activity_line(line)

      (handoff = HandoffLine.parse(line)) != nil ->
        state =
          state
          |> flush_handoff()
          |> flush_human()
          |> flush_activity()
          |> flush_role()

        if handoff.direction == :received do
          %{state | pending_handoff: handoff, pending_handoff_line: line}
        else
          turn = %ChatTurn{
            role: :system,
            author: :event,
            content: line,
            text: line,
            handoff: handoff
          }

          %{state | turns: [turn | state.turns]}
        end

      Regex.match?(@system_prefix, line) ->
        turn = %ChatTurn{
          role: :system,
          author: :event,
          content: line,
          text: line
        }

        state
        |> flush_handoff()
        |> flush_human()
        |> flush_activity()
        |> flush_role()
        |> append_turn(turn)

      true ->
        state
        |> flush_handoff()
        |> flush_human()
        |> flush_activity()
        |> append_role_line(line)
    end
  end

  defp append_activity_line(state, line) do
    %{state | activity_lines: [line | state.activity_lines]}
  end

  defp append_role_line(state, line) do
    %{state | role_lines: [line | state.role_lines]}
  end

  defp append_turn(state, turn) do
    %{state | turns: [turn | state.turns]}
  end

  defp flush_human(%{human_lines: nil} = state), do: state

  defp flush_human(%{human_lines: lines} = state) do
    text = lines |> Enum.reverse() |> Enum.join("\n")

    turn = %ChatTurn{
      role: :user,
      author: :human,
      content: text,
      text: text
    }

    %{state | human_lines: nil, turns: [turn | state.turns]}
  end

  defp flush_activity(%{activity_lines: []} = state), do: state

  defp flush_activity(%{activity_lines: lines} = state) do
    text = lines |> Enum.reverse() |> Enum.join("\n")

    turn = %ChatTurn{
      role: :system,
      author: :activity,
      content: text,
      text: text
    }

    %{state | activity_lines: [], turns: [turn | state.turns]}
  end

  defp flush_role(%{role_lines: []} = state), do: state

  defp flush_role(%{role_lines: lines} = state) do
    text = lines |> Enum.reverse() |> Enum.join("\n")

    turn = %ChatTurn{
      role: :agent,
      author: :role,
      content: text,
      text: text
    }

    %{state | role_lines: [], turns: [turn | state.turns]}
  end

  defp flush_handoff(%{pending_handoff: nil} = state), do: state

  defp flush_handoff(%{pending_handoff: handoff} = state) do
    note =
      case state.handoff_note_lines do
        [] ->
          ""

        lines ->
          lines
          |> Enum.reverse()
          |> Enum.join("\n")
          |> String.trim()
      end

    final_handoff =
      if note == "" do
        handoff
      else
        %{handoff | note: note}
      end

    turn = %ChatTurn{
      role: :system,
      author: :event,
      content: state.pending_handoff_line || "",
      text: state.pending_handoff_line || "",
      handoff: final_handoff
    }

    %{
      state
      | pending_handoff: nil,
        pending_handoff_line: nil,
        handoff_note_lines: [],
        turns: [turn | state.turns]
    }
  end

  defp sync_messages_and_turns(changeset) do
    turns = get_change(changeset, :turns)
    messages = get_change(changeset, :messages)

    cond do
      is_list(turns) and is_nil(messages) ->
        put_change(changeset, :messages, turns)

      is_list(messages) and is_nil(turns) ->
        put_change(changeset, :turns, messages)

      true ->
        changeset
    end
  end
end

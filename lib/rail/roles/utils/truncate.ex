defmodule Rail.Roles.Utils.Truncate do
  @moduledoc """
  Deterministic head/tail text truncation helper.
  """

  @doc """
  Truncates `text` keeping `head_chars` from the start and `tail_chars` from the end
  if the text length exceeds `max_chars` and omitted character count > 0.
  """
  def truncate_head_tail(text, max_chars \\ 4000, head_chars \\ 2000, tail_chars \\ 2000)

  def truncate_head_tail(nil, _max_chars, _head_chars, _tail_chars), do: ""

  def truncate_head_tail(text, max_chars, head_chars, tail_chars)
      when is_binary(text) and is_integer(max_chars) and is_integer(head_chars) and is_integer(tail_chars) do
    len = String.length(text)

    if len <= max_chars do
      text
    else
      omitted = len - head_chars - tail_chars

      if omitted <= 0 do
        text
      else
        head = String.slice(text, 0, head_chars)
        tail = String.slice(text, len - tail_chars, tail_chars)
        "#{head}\n\n[... #{omitted} characters truncated ...]\n\n#{tail}"
      end
    end
  end
end

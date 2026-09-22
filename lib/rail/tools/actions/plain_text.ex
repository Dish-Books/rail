defmodule Rail.Tools.Actions.PlainText do
  @moduledoc false

  # CSI sequences (colors, cursor moves) and OSC sequences (titles, links).
  @escape ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[@-Z\\-_]/

  @doc """
  Reads what a command wrote to a terminal as the text a person would have seen:
  escape sequences dropped, and a line redrawn with carriage returns as it ended.
  """
  def plain_text(text) when is_binary(text) do
    text
    |> String.replace(@escape, "")
    |> String.split("\n")
    |> Enum.map_join("\n", &(&1 |> String.trim_trailing("\r") |> String.split("\r") |> List.last()))
  end
end

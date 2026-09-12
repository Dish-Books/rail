defmodule RailWeb.Utils.FormatRunStatus do
  @moduledoc false

  @doc """
  Formats a run status as lowerCamel: `:blocked_on_input` becomes `"blockedOnInput"`.
  """
  def format_run_status(nil), do: ""
  def format_run_status(""), do: ""
  def format_run_status(status) when is_atom(status), do: status |> Atom.to_string() |> format_run_status()

  def format_run_status(status) when is_binary(status) do
    [first | rest] = String.split(status, "_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end
end

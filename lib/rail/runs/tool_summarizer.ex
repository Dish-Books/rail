defmodule Rail.Runs.ToolSummarizer do
  @moduledoc """
  Summarizes tool call inputs into compact strings for log transcript lines.

  Prioritizes common file, command, query, and path parameters across Claude and Agy,
  falling back to a comma-separated key list when none match.
  """

  @prioritized_keys [
    "file_path",
    "path",
    "command",
    "pattern",
    "query",
    "url",
    "AbsolutePath",
    "TargetFile",
    "CommandLine",
    "Pattern",
    "Query",
    "SearchDirectory",
    "DirectoryPath"
  ]

  @key_pairs Enum.map(@prioritized_keys, fn key -> {key, String.to_atom(key)} end)

  @doc """
  Summarizes tool input parameters into a short string.

  Supports 1-arity `summarize_tool_input(params)` and 2-arity `summarize_tool_input(tool_name, params)`.
  """
  def summarize_tool_input(tool_name, params) when is_binary(tool_name) or is_atom(tool_name) do
    summarize_tool_input(params)
  end

  def summarize_tool_input(params) when is_map(params) do
    case find_first_matching_value(params, @key_pairs) do
      {:ok, val} ->
        truncate(to_string(val), 160)

      :none ->
        keys_summary =
          params
          |> Map.keys()
          |> Enum.map_join(", ", &to_string/1)

        truncate(keys_summary, 80)
    end
  end

  def summarize_tool_input(params) when is_binary(params) do
    truncate(params, 160)
  end

  def summarize_tool_input(_non_map_params), do: ""

  @doc """
  Replaces newlines with spaces, trims, and truncates `text` to `max` characters,
  appending an ellipsis (U+2026) when truncated.
  """
  def truncate(nil, _max_length), do: ""

  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    flat =
      text
      |> String.replace("\n", " ")
      |> String.trim()

    if String.length(flat) <= max_length do
      flat
    else
      String.slice(flat, 0, max_length) <> "…"
    end
  end

  def truncate(other, max_length) when is_integer(max_length) do
    truncate(to_string(other), max_length)
  end

  defp find_first_matching_value(map, [{str_key, atom_key} | rest]) do
    case Map.fetch(map, str_key) do
      {:ok, nil} ->
        find_first_matching_value(map, rest)

      {:ok, val} ->
        {:ok, val}

      :error ->
        case Map.fetch(map, atom_key) do
          {:ok, nil} ->
            find_first_matching_value(map, rest)

          {:ok, val} ->
            {:ok, val}

          :error ->
            find_first_matching_value(map, rest)
        end
    end
  end

  defp find_first_matching_value(_map, []), do: :none
end

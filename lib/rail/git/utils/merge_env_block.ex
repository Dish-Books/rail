defmodule Rail.Git.Utils.MergeEnvBlock do
  @moduledoc false

  @open "# >>> Rail: the project's .env, rewritten on every save >>>"
  @close "# <<< Rail: the project's .env <<<"

  @doc """
  The checkout's `.env` with `project_env` written into its top between Rail's markers, `current` being the file as it
  stands, or nil when there is none: each of its own lines that sets no variable the project's does is kept.
  """
  def merge_env_block(project_env, current) when is_binary(project_env) do
    ours = project_env |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == ""))
    # Comments and blank lines name no variable, so they never knock out a checkout's own.
    names = ours |> Enum.map(&variable/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    kept =
      if is_binary(current),
        do:
          current |> String.trim_trailing() |> String.split("\n") |> drop_block() |> Enum.reject(&(variable(&1) in names)),
        else: []

    Enum.join([@open | ours] ++ [@close | kept], "\n") <> "\n"
  end

  # A setup script rerun keeps the block below its own, so it is looked for anywhere in the file.
  defp drop_block(lines) do
    {kept, _in_block} =
      Enum.flat_map_reduce(lines, false, fn
        @open, _in_block -> {[], true}
        @close, _in_block -> {[], false}
        _line, true -> {[], true}
        line, false -> {[line], false}
      end)

    Enum.drop_while(kept, &(&1 == ""))
  end

  defp variable(line) do
    case Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=/, line) do
      [_line, name] -> name
      nil -> nil
    end
  end
end

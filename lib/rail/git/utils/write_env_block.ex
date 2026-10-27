defmodule Rail.Git.Utils.WriteEnvBlock do
  @moduledoc false

  alias Rail.Projects.Schemas.Project

  @open "# >>> Rail: the project's .env, rewritten on every save >>>"
  @close "# <<< Rail: the project's .env <<<"

  @doc """
  Writes the clone's `.env` into the top of `worktree_path`'s, between Rail's markers, keeping each of the
  worktree's own lines that sets no variable the clone's does. Takes no lock: callers hold the clone's.
  """
  def write_env_block(%Project{clone_path: clone}, worktree_path) when is_binary(worktree_path) do
    case File.read(Path.join(clone, ".env")) do
      {:ok, project_env} ->
        ours = project_env |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == ""))
        # Comments and blank lines name no variable, so they never knock out a worktree's own.
        names = ours |> Enum.map(&variable/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
        target = Path.join(worktree_path, ".env")

        kept =
          case File.read(target) do
            {:ok, text} ->
              text
              |> String.trim_trailing()
              |> String.split("\n")
              |> drop_block()
              |> Enum.reject(&MapSet.member?(names, variable(&1)))

            {:error, :enoent} ->
              []
          end

        exclude_env(clone)
        File.write(target, Enum.join([@open | ours] ++ [@close | kept], "\n") <> "\n")

      {:error, :enoent} ->
        :ok
    end
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

  # Every worktree reads the clone's exclude file, so the file never shows as a change in any of them.
  defp exclude_env(clone) do
    info = Path.join([clone, ".git", "info"])
    exclude = Path.join(info, "exclude")
    File.mkdir_p!(info)

    case File.read(exclude) do
      {:ok, text} ->
        if "/.env" not in String.split(text, ~r/\r?\n/),
          do: File.write!(exclude, String.trim_trailing(text) <> "\n/.env\n")

      {:error, :enoent} ->
        File.write!(exclude, "/.env\n")
    end
  end
end

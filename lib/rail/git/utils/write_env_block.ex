defmodule Rail.Git.Utils.WriteEnvBlock do
  @moduledoc false

  alias Rail.Projects.Schemas.Project

  @open "# >>> Rail: the project's .env, rewritten on every save >>>"
  @close "# <<< Rail: the project's .env <<<"

  @doc """
  Writes the clone's `.env` into the top of `worktree_path`'s, between Rail's markers, keeping each of the
  worktree's own lines that sets no variable the clone's does. Returns `:ok` or `{:error, "<path>: <reason>"}`.
  """
  # Takes no lock: callers hold the clone's.
  def write_env_block(%Project{clone_path: clone}, worktree_path) when is_binary(worktree_path) do
    source = Path.join(clone, ".env")

    case File.read(source) do
      {:ok, project_env} ->
        ours = project_env |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == ""))
        # Comments and blank lines name no variable, so they never knock out a worktree's own.
        names = ours |> Enum.map(&variable/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
        target = Path.join(worktree_path, ".env")

        kept =
          case File.read(target) do
            {:ok, text} ->
              lines =
                text
                |> String.trim_trailing()
                |> String.split("\n")
                |> drop_block()
                |> Enum.reject(&MapSet.member?(names, variable(&1)))

              {:ok, lines}

            {:error, :enoent} ->
              {:ok, []}

            {:error, reason} ->
              said({:error, reason}, target)
          end

        with {:ok, kept} <- kept,
             :ok <- exclude_env(clone) do
          target |> File.write(Enum.join([@open | ours] ++ [@close | kept], "\n") <> "\n") |> said(target)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        said({:error, reason}, source)
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

    with :ok <- info |> File.mkdir_p() |> said(info) do
      case File.read(exclude) do
        {:ok, text} ->
          if "/.env" in String.split(text, ~r/\r?\n/),
            do: :ok,
            else: exclude |> File.write(String.trim_trailing(text) <> "\n/.env\n") |> said(exclude)

        {:error, :enoent} ->
          exclude |> File.write("/.env\n") |> said(exclude)

        {:error, reason} ->
          said({:error, reason}, exclude)
      end
    end
  end

  defp said(:ok, _path), do: :ok
  defp said({:error, reason}, path), do: {:error, "#{path}: #{:file.format_error(reason)}"}
end

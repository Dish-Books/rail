defmodule Rail.Git.Actions.GetChangedFiles do
  @moduledoc false

  import Rail.Git.Utils.GitCmd

  alias Rail.Git.ChangedFile

  @doc """
  Returns a list of ChangedFile structs for modified, deleted, and untracked files.
  """
  def get_changed_files(worktree_path, opts \\ []) when is_binary(worktree_path) do
    filter = Keyword.get(opts, :filter)

    args =
      cond do
        is_nil(filter) or filter == "uncommitted" ->
          ["diff", "--numstat", "HEAD"]

        filter == "main" ->
          ["diff", "--numstat", "main...HEAD"]

        true ->
          ["diff", "--numstat", filter]
      end

    case git_cmd(args, cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} ->
        parse_numstat(output, worktree_path, filter)

      _other ->
        []
    end
  end

  defp parse_numstat(output, worktree_path, filter) do
    tracked_files =
      for line <- String.split(output, ~r/\r?\n/, trim: true),
          parts = String.split(line, ~r/\s+/, parts: 3),
          length(parts) == 3 do
        [adds_str, dels_str, relative_path] = parts
        additions = parse_int(adds_str)
        deletions = parse_int(dels_str)
        full_path = Path.join(worktree_path, relative_path)

        case File.read(full_path) do
          {:ok, bytes} ->
            content_hash =
              :sha256
              |> :crypto.hash(bytes)
              |> Base.encode16(case: :lower)

            %ChangedFile{
              file_path: relative_path,
              additions: additions,
              deletions: deletions,
              content_hash: content_hash,
              status: "modified"
            }

          _error ->
            %ChangedFile{
              file_path: relative_path,
              additions: additions,
              deletions: deletions,
              content_hash: nil,
              status: "deleted"
            }
        end
      end

    if is_nil(filter) or filter == "uncommitted" do
      append_untracked(tracked_files, worktree_path)
    else
      tracked_files
    end
  end

  defp append_untracked(tracked_files, worktree_path) do
    tracked_paths = MapSet.new(Enum.map(tracked_files, & &1.file_path))

    untracked_files =
      worktree_path
      |> Rail.Git.list_untracked_files()
      |> Enum.reject(&MapSet.member?(tracked_paths, &1))
      |> Enum.reduce([], fn path, acc ->
        case build_untracked_file(worktree_path, path) do
          %ChangedFile{} = file -> [file | acc]
          nil -> acc
        end
      end)
      |> Enum.reverse()

    tracked_files ++ untracked_files
  end

  defp build_untracked_file(worktree_path, path) do
    full_path = Path.join(worktree_path, path)

    case File.read(full_path) do
      {:ok, bytes} ->
        content_hash =
          :sha256
          |> :crypto.hash(bytes)
          |> Base.encode16(case: :lower)

        is_binary_file = String.contains?(bytes, <<0>>)
        additions = if is_binary_file, do: 0, else: count_lines(bytes)

        %ChangedFile{
          file_path: path,
          additions: additions,
          deletions: 0,
          content_hash: content_hash,
          status: "added"
        }

      _error ->
        nil
    end
  end

  defp count_lines(bytes) do
    case String.split(bytes, ~r/\r?\n/) do
      [""] ->
        0

      list ->
        if List.last(list) == "" do
          length(list) - 1
        else
          length(list)
        end
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {num, _rest} -> num
      :error -> 0
    end
  end
end

defmodule Rail.Git.Actions.SynthesizeUntrackedDiff do
  @moduledoc false

  @doc """
  Synthesizes a git-diff patch for an untracked file.
  """
  def synthesize_untracked_diff(worktree_path, relative_path)
      when is_binary(worktree_path) and is_binary(relative_path) do
    full_path = Path.join(worktree_path, relative_path)

    case File.read(full_path) do
      {:ok, bytes} ->
        if String.contains?(bytes, <<0>>) do
          "diff --git a/#{relative_path} b/#{relative_path}\n" <>
            "new file (untracked)\n" <>
            "Binary file #{relative_path} differs\n"
        else
          format_text_diff(relative_path, bytes)
        end

      _error ->
        ""
    end
  end

  defp format_text_diff(relative_path, bytes) do
    lines =
      case String.split(bytes, ~r/\r?\n/) do
        [""] ->
          []

        list ->
          if List.last(list) == "" do
            Enum.slice(list, 0..-2//1)
          else
            list
          end
      end

    count = length(lines)

    header =
      "diff --git a/#{relative_path} b/#{relative_path}\n" <>
        "new file (untracked)\n" <>
        "--- /dev/null\n" <>
        "+++ b/#{relative_path}\n" <>
        "@@ -0,0 +1,#{count} @@\n"

    body =
      Enum.map_join(lines, "", fn line -> "+#{line}\n" end)

    header <> body
  end
end

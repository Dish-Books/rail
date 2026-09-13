defmodule Rail.Git.Actions.GetDiff do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Gets the git diff for the worktree according to filter, synthesizing untracked files
  for uncommitted diffs.
  """
  def get_diff(worktree_path) when is_binary(worktree_path) do
    do_get_diff(worktree_path, nil)
  end

  def get_diff(worktree_path, opts) when is_binary(worktree_path) and is_list(opts) do
    filter = Keyword.get(opts, :filter)
    do_get_diff(worktree_path, filter)
  end

  def get_diff(worktree_path, filter) when is_binary(worktree_path) do
    do_get_diff(worktree_path, filter)
  end

  defp do_get_diff(worktree_path, filter) do
    filter_norm = normalize_filter(filter)
    args = diff_args(filter_norm)

    diff_output =
      case Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true) do
        {out, 0} ->
          out

        _fallback ->
          {out_fallback, _code} =
            Tools.run("git", ["diff"], cd: worktree_path, stderr_to_stdout: true)

          out_fallback
      end

    if is_nil(filter_norm) or filter_norm == "uncommitted" do
      untracked_diffs =
        worktree_path
        |> Rail.Git.list_untracked_files()
        |> Enum.map_join("", fn path -> Rail.Git.synthesize_untracked_diff(worktree_path, path) end)

      diff_output <> untracked_diffs
    else
      diff_output
    end
  end

  defp normalize_filter(:uncommitted), do: "uncommitted"
  defp normalize_filter(:main), do: "main"
  defp normalize_filter(binary) when is_binary(binary), do: binary
  defp normalize_filter(atom) when is_atom(atom) and atom not in [true, false, nil], do: Atom.to_string(atom)
  defp normalize_filter(_other), do: nil

  defp diff_args(filter) when is_nil(filter) or filter == "uncommitted", do: ["diff", "HEAD"]
  defp diff_args("main"), do: ["diff", "main...HEAD"]
  defp diff_args(filter), do: ["diff", filter]
end

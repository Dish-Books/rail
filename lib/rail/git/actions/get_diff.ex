defmodule Rail.Git.Actions.GetDiff do
  @moduledoc false

  import Rail.Git.Utils.GitCmd

  @doc """
  Gets the git diff for the worktree according to filter, synthesizing untracked files
  for uncommitted diffs.
  """
  def get_diff(worktree_path, filter \\ nil) when is_binary(worktree_path) do
    args =
      cond do
        is_nil(filter) or filter == "uncommitted" ->
          ["diff", "HEAD"]

        filter == "main" ->
          ["diff", "main...HEAD"]

        true ->
          ["diff", filter]
      end

    diff_output =
      case git_cmd(args, cd: worktree_path, stderr_to_stdout: true) do
        {out, 0} ->
          out

        _fallback ->
          {out_fallback, _code} = git_cmd(["diff"], cd: worktree_path, stderr_to_stdout: true)
          out_fallback
      end

    if is_nil(filter) or filter == "uncommitted" do
      untracked_diffs =
        worktree_path
        |> Rail.Git.list_untracked_files()
        |> Enum.map_join("", fn path -> Rail.Git.synthesize_untracked_diff(worktree_path, path) end)

      diff_output <> untracked_diffs
    else
      diff_output
    end
  end
end

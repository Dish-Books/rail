defmodule Rail.Git.Actions.GetOrCreateWorktree do
  @moduledoc false

  import Rail.Git.Utils.GitCmd

  @doc """
  Gets an existing worktree directory or creates a new one using the branch ladder.
  """
  def get_or_create_worktree(repo_path, worktree_path, branch, opts)
      when is_binary(repo_path) and is_binary(worktree_path) and is_binary(branch) do
    if File.dir?(worktree_path) do
      {:ok, worktree_path}
    else
      File.mkdir_p!(Path.dirname(worktree_path))
      base_branch = Keyword.get(opts, :base_branch, "main")

      case try_ladder(repo_path, worktree_path, branch, base_branch) do
        :ok ->
          {:ok, worktree_path}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp try_ladder(repo_path, worktree_path, branch, base_branch) do
    # Step 1: create new branch based on base_branch
    res1 =
      git_cmd(["worktree", "add", "-b", branch, worktree_path, base_branch],
        cd: repo_path,
        stderr_to_stdout: true
      )

    case res1 do
      {_out, 0} ->
        :ok

      _fail1 ->
        # Step 2: checkout existing branch
        res2 =
          git_cmd(["worktree", "add", worktree_path, branch],
            cd: repo_path,
            stderr_to_stdout: true
          )

        case res2 do
          {_out, 0} ->
            :ok

          _fail2 ->
            # Step 3: detached HEAD
            res3 =
              git_cmd(["worktree", "add", worktree_path],
                cd: repo_path,
                stderr_to_stdout: true
              )

            case res3 do
              {_out, 0} ->
                :ok

              _fail3 ->
                {:error,
                 "Failed to create worktree at #{worktree_path}:\n" <>
                   "  attempt 1 (-b #{branch} #{base_branch}): #{describe(res1)}\n" <>
                   "  attempt 2 (#{branch}): #{describe(res2)}\n" <>
                   "  attempt 3 (detached): #{describe(res3)}"}
            end
        end
    end
  end

  defp describe({output, code}) do
    trimmed = String.trim(output)
    "exit #{code}: #{trimmed}"
  end
end

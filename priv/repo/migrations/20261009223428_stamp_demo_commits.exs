defmodule Rail.Repo.Migrations.StampDemoCommits do
  use Ecto.Migration

  # A demo saved before demos carried their commit is stamped with the commit its branch was on when its
  # video was written, so the Demo item can say how far behind it is. A task with no worktree left stays unstamped.
  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, tasks.worktree_path, issues.identifier
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, worktree_path, identifier] <- rows do
      stamp(
        Path.join([scratch_path, "demo", "#{identifier}.json"]),
        Path.join([scratch_path, "demo", "demo.webm"]),
        worktree_path
      )
    end
  end

  def down, do: :ok

  defp stamp(path, video, worktree_path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = demo} <- Jason.decode(content),
         false <- is_binary(demo["commit"]),
         {:ok, %File.Stat{mtime: written}} <- File.stat(video, time: :posix),
         {sha, 0} <-
           Rail.Tools.run("git", ["log", "-1", "--first-parent", "--format=%H", "--before=@#{written}", "HEAD"],
             cd: worktree_path,
             stderr_to_stdout: true
           ),
         [sha] <- String.split(sha) do
      temporary = path <> ".stamp"
      File.write!(temporary, Jason.encode!(Map.put(demo, "commit", sha), pretty: true))
      File.rename!(temporary, path)
    end
  end
end

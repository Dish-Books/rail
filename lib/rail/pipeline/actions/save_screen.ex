defmodule Rail.Pipeline.Actions.SaveScreen do
  @moduledoc """
  Records a shot an explorer took of one screen state beside the picture in the QA folder, stamped with
  HEAD's commit and the time, which are Rail's to say. A state keeps only its latest shot, so a retake
  deletes the pictures and records before it.
  """

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `file`, a picture under `screens/<key>/` in `task`'s QA folder, as the shot of the screen state `key`
  reading `label`, taken in `browser`. Returns `{:ok, shot}` with the commit it was taken on.
  """
  def save_screen(%Task{} = task, %{key: key, label: label, file: file} = attrs) do
    head = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    shot = %{key: key, label: label, file: file, browser: attrs[:browser], commit: head, taken_at: DateTime.utc_now()}
    record = Path.rootname(file) <> ".json"

    write_scratch_file(Path.join([task.scratch_path, "qa", record]), Jason.encode!(shot))
    remove_earlier(Path.join([task.scratch_path, "qa", "screens", key]), [Path.basename(file), Path.basename(record)])
    Pipeline.broadcast_output_saved(task)

    {:ok, shot}
  end

  # `lstat` so a link an agent left is removed as a link and never followed out of the folder.
  defp remove_earlier(folder, kept) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         {:ok, names} <- File.ls(folder) do
      for name <- names -- kept,
          path = Path.join(folder, name),
          match?({:ok, %File.Stat{type: type}} when type in [:regular, :symlink], File.lstat(path)),
          do: File.rm(path)
    end
  end
end

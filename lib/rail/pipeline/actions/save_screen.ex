defmodule Rail.Pipeline.Actions.SaveScreen do
  @moduledoc """
  Records a shot an explorer took of one screen state beside the picture in the QA folder, stamped with
  HEAD's commit and the time, which are Rail's to say. A state keeps every shot, one per retake.
  """

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `file`, a picture under `screens/<key>/` in `task`'s QA folder, as a shot of the screen state `key`
  reading `label`, taken in `browser`. Returns `{:ok, shot}` with the commit it was taken on.
  """
  def save_screen(%Task{} = task, %{key: key, label: label, file: file} = attrs) do
    head = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    shot = %{key: key, label: label, file: file, browser: attrs[:browser], commit: head, taken_at: DateTime.utc_now()}

    write_scratch_file(Path.join([task.scratch_path, "qa", Path.rootname(file) <> ".json"]), Jason.encode!(shot))
    Pipeline.broadcast_output_saved(task)

    {:ok, shot}
  end
end

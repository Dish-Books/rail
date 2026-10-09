defmodule Rail.Pipeline.Actions.SaveDemo do
  @moduledoc """
  Checks the write-up the demo recorder saved, writes it where `read_demo/1` reads it, stops the recording
  and queues its encode. Saving is how the recorder says the take is over, so the encode does not wait for
  the Review run, which goes on long after the demo.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.EncodeDemo
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  Saves `attrs` as `task`'s demo write-up and queues the encode. Returns `{:ok, demo}` or `{:error, changeset}`.
  """
  def save_demo(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)

    with {:ok, %Demo{} = demo} <- %Demo{} |> Demo.changeset(attrs) |> apply_action(:insert) do
      head = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
      body = %{title: demo.title, summary: demo.summary, not_shown: demo.not_shown, commit: head}

      write_scratch_file(Path.join([task.scratch_path, "demo", "#{identifier}.json"]), Jason.encode!(body, pretty: true))
      _directory = Tools.stop_browser_recording(task)
      {:ok, _job} = %{task_id: task.id} |> EncodeDemo.new() |> Oban.insert()
      Pipeline.broadcast_output_saved(task)

      {:ok, %{demo | commit: head}}
    end
  end
end

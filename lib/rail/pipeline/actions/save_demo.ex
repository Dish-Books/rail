defmodule Rail.Pipeline.Actions.SaveDemo do
  @moduledoc """
  Checks the write-up a demo run saved and writes it where `read_demo/1` reads it.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs` as `task`'s demo write-up. Returns `{:ok, demo}` or `{:error, changeset}`.
  """
  def save_demo(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)

    with {:ok, %Demo{} = demo} <- %Demo{} |> Demo.changeset(attrs) |> apply_action(:insert) do
      body = %{title: demo.title, summary: demo.summary, not_shown: demo.not_shown}

      write_scratch_file(Path.join([task.scratch_path, "demo", "#{identifier}.json"]), Jason.encode!(body, pretty: true))
      Pipeline.broadcast_output_saved(task)

      {:ok, demo}
    end
  end
end

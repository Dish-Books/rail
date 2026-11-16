defmodule Rail.Pipeline.Actions.GetPreviewTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Preview

  setup %{project: project} do
    task = learnings_task(project, "GPV-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    %{task: task}
  end

  test "a task's preview is what Rail last saw of it, and nothing before it ever looked", %{task: task} do
    assert Pipeline.get_preview(task) == nil

    %Preview{id: id} = Repo.insert!(%Preview{task_id: task.id, url: "https://pr-7.preview.example.com", status: :live})

    assert %Preview{id: ^id, status: :live} = Pipeline.get_preview(task)
  end
end

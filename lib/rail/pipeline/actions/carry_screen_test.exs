defmodule Rail.Pipeline.Actions.CarryScreenTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round

  setup %{project: project} do
    task = learnings_task(project, "CSC-1", :review)
    qa = Path.join(task.scratch_path, "qa")
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")
    Repo.insert!(%Round{task_id: task.id, number: 1})

    for key <- ["toolbar", "file-list"] do
      File.mkdir_p!(Path.join([qa, "screens", key]))
      File.write!(Path.join([qa, "screens", key, "1.jpg"]), "jpeg")
      shot = %{label: key, commit: "c1", browser: "explorer-1", taken_at: "2026-10-08T09:00:00Z", round: 1}
      File.write!(Path.join([qa, "screens", key, "1.json"]), Jason.encode!(shot))
    end

    Repo.insert!(%Round{task_id: task.id, number: 2})

    %{task: task}
  end

  # The picture is of the commit it was taken on, whichever round carries it.
  test "carries a state into the current round as it is, so Screens shows it beside this round's", %{
    task: %{id: task_id} = task
  } do
    assert {:ok, %{key: "toolbar", round: 2, commit: "c1", taken_at: ~U[2026-10-08 09:00:00Z]}} =
             Pipeline.carry_screen(task, "toolbar")

    assert [%{key: "toolbar", round: 2, file: "screens/toolbar/1.jpg", commit: "c1", browser: "explorer-1"}] =
             Pipeline.list_screens(task)

    assert_received {:output_saved, ^task_id}
  end

  test "refuses a state this round already has, and one no round shot", %{task: task} do
    {:ok, _carried} = Pipeline.carry_screen(task, "toolbar")

    assert {:error, :current} = Pipeline.carry_screen(task, "toolbar")
    assert {:error, :not_found} = Pipeline.carry_screen(task, "activity")
  end
end

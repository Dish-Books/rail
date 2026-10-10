defmodule Rail.Pipeline.Actions.SaveScreenTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  setup %{project: project} do
    task = learnings_task(project, "SSC-1", :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task, head: worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()}
  end

  # When and on which commit are Rail's to say, written beside the picture it describes.
  test "records the shot against HEAD's commit beside its picture, and tells the open page", %{
    task: %{id: task_id} = task,
    head: head
  } do
    file = "screens/toolbar/1760000000000000.jpg"

    assert {:ok,
            %{key: "toolbar", label: "Toolbar at 1280px", commit: ^head, browser: "explorer-2", taken_at: %DateTime{}}} =
             Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar at 1280px", file: file, browser: "explorer-2"})

    assert %{"commit" => ^head, "label" => "Toolbar at 1280px", "browser" => "explorer-2"} =
             [task.scratch_path, "qa", "screens/toolbar/1760000000000000.json"]
             |> Path.join()
             |> File.read!()
             |> Jason.decode!()

    assert_received {:output_saved, ^task_id}
  end

  test "a task whose worktree is gone records a shot on no commit", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {:ok, %{commit: nil}} =
             Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})
  end
end

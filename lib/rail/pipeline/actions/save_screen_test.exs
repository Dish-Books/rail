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

  test "a retake leaves only the new picture and record in the state's folder, and other states' alone", %{
    task: task
  } do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join([qa, "screens", "toolbar"]))
    File.mkdir_p!(Path.join([qa, "screens", "file-list"]))
    outside = Path.join(System.tmp_dir!(), "rail_save_screen_#{System.unique_integer([:positive])}.jpg")
    File.write!(outside, "keep me")
    on_exit(fn -> File.rm(outside) end)

    for {key, stamp} <- [{"toolbar", "1"}, {"toolbar", "2"}, {"file-list", "1"}] do
      File.write!(Path.join([qa, "screens", key, "#{stamp}.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: key, label: key, file: "screens/#{key}/#{stamp}.jpg"})
    end

    File.ln_s!(outside, Path.join([qa, "screens", "toolbar", "link.jpg"]))
    File.write!(Path.join([qa, "screens", "toolbar", "3.jpg"]), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/3.jpg"})

    assert ["3.jpg", "3.json"] = qa |> Path.join("screens/toolbar") |> File.ls!() |> Enum.sort()
    assert ["1.jpg", "1.json"] = qa |> Path.join("screens/file-list") |> File.ls!() |> Enum.sort()
    assert File.read!(outside) == "keep me"
  end

  test "a task whose worktree is gone records a shot on no commit", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {:ok, %{commit: nil}} =
             Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})
  end
end

defmodule Rail.Pipeline.Actions.ListScreensTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  setup %{project: project} do
    # The task has no worktree, so a finding saved here is on no commit: which one is not what is listed.
    task = learnings_task(project, "LSC-1", :review)
    qa = Path.join(task.scratch_path, "qa")
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, qa: qa}
  end

  # Each shot is a picture and the record beside it, as save_screen writes them.
  test "lists each state once by its newest shot, by label then key, with what cites that picture", %{
    task: task,
    qa: qa
  } do
    for {key, stamp, label, at} <- [
          {"toolbar", "3", "Toolbar", "2026-10-08T09:00:00Z"},
          {"file-list", "1", "File list", "2026-10-07T16:00:00Z"},
          {"file-list", "2", "File list just after Send", "2026-10-08T09:01:00Z"},
          {"activity", "4", "Toolbar", "2026-10-07T16:00:00Z"}
        ] do
      File.mkdir_p!(Path.join([qa, "screens", key]))
      File.write!(Path.join([qa, "screens", key, "#{stamp}.jpg"]), "jpeg")

      File.write!(
        Path.join([qa, "screens", key, "#{stamp}.json"]),
        Jason.encode!(%{label: label, commit: "c#{stamp}", browser: "explorer-1", taken_at: at})
      )
    end

    {:ok, _cited} =
      Pipeline.save_finding(task, %{
        key: "count-stale",
        kind: :screen,
        raised_by: :explorer,
        title: "The file list still counts unsent comments",
        problem: "It counts three after Send.",
        screen: "Engineer tab",
        steps: ["Send"],
        fix: "Recount after Send.",
        why: "It misleads.",
        rule: "Counts follow what was sent.",
        severity: :major,
        recommendation: :fix,
        places: [%{screen: "Engineer tab"}],
        evidence: [%{name: "The list", kind: :screenshot, path: "screens/file-list/2.jpg"}]
      })

    assert [
             %{
               key: "file-list",
               label: "File list just after Send",
               file: "screens/file-list/2.jpg",
               commit: "c2",
               browser: "explorer-1",
               findings: [%{key: "count-stale", title: "The file list still counts unsent comments"}]
             },
             %{key: "activity", label: "Toolbar", file: "screens/activity/4.jpg", findings: []},
             %{key: "toolbar", commit: "c3", taken_at: ~U[2026-10-08 09:00:00Z], findings: []}
           ] = Pipeline.list_screens(task)
  end

  # A finding that cited only a replaced picture drops off until it cites the new one.
  test "a finding citing a state's earlier picture is not listed with it", %{task: task, qa: qa} do
    File.mkdir_p!(Path.join([qa, "screens", "toolbar"]))

    for {stamp, at} <- [{"1", "2026-10-07T16:00:00Z"}, {"2", "2026-10-08T09:00:00Z"}] do
      File.write!(Path.join([qa, "screens", "toolbar", "#{stamp}.jpg"]), "jpeg")

      File.write!(
        Path.join([qa, "screens", "toolbar", "#{stamp}.json"]),
        Jason.encode!(%{label: "Toolbar", taken_at: at})
      )
    end

    {:ok, _cited} =
      Pipeline.save_finding(task, %{
        key: "toolbar-wraps",
        kind: :screen,
        raised_by: :explorer,
        title: "The toolbar wraps",
        problem: "It wraps at 1280px.",
        screen: "Engineer tab",
        steps: ["Open"],
        fix: "Fold it.",
        why: "It misleads.",
        rule: "Toolbars fit.",
        severity: :minor,
        recommendation: :fix,
        places: [%{screen: "Engineer tab"}],
        evidence: [%{name: "The bar", kind: :screenshot, path: "screens/toolbar/1.jpg"}]
      })

    assert [%{key: "toolbar", file: "screens/toolbar/2.jpg", findings: []}] = Pipeline.list_screens(task)
  end

  test "a task with no screens has none", %{task: task} do
    assert [] = Pipeline.list_screens(task)
  end

  # Anything under scratch may have been written by an agent, so only Rail's own shape is read.
  test "passes over a record that is not the shape Rail writes, or whose picture is missing or a link", %{
    task: task,
    qa: qa
  } do
    folder = Path.join([qa, "screens", "toolbar"])
    File.mkdir_p!(folder)
    outside = Path.join(System.tmp_dir!(), "rail_list_screens_#{System.unique_integer([:positive])}.jpg")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)
    good = Jason.encode!(%{label: "Toolbar", taken_at: "2026-10-08T09:00:00Z"})

    File.write!(Path.join(folder, "1.jpg"), "jpeg")
    File.write!(Path.join(folder, "1.json"), "not json")
    File.write!(Path.join(folder, "2.jpg"), "jpeg")
    File.write!(Path.join(folder, "2.json"), Jason.encode!(%{label: 7, taken_at: "2026-10-08T09:00:00Z"}))
    File.write!(Path.join(folder, "3.jpg"), "jpeg")
    File.write!(Path.join(folder, "3.json"), Jason.encode!(%{label: "Toolbar", taken_at: "yesterday"}))
    File.write!(Path.join(folder, "4.json"), good)
    File.ln_s!(outside, Path.join(folder, "5.jpg"))
    File.write!(Path.join(folder, "5.json"), good)
    File.mkdir_p!(Path.join([qa, "screens", "Not A Key"]))
    File.write!(Path.join([qa, "screens", "Not A Key", "6.jpg"]), "jpeg")
    File.write!(Path.join([qa, "screens", "Not A Key", "6.json"]), good)
    File.write!(Path.join(folder, "7.jpg"), "jpeg")

    File.write!(
      Path.join(folder, "7.json"),
      Jason.encode!(%{label: "Toolbar", taken_at: "2026-10-08T10:00:00Z", commit: 7})
    )

    assert [%{key: "toolbar", file: "screens/toolbar/7.jpg", commit: nil, browser: nil}] =
             Pipeline.list_screens(task)
  end
end

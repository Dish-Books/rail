defmodule Rail.Pipeline.Actions.SaveDesignOptionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Repo

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sdo_1", "identifier" => "SDO-1", "title" => "Save Design Option"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Save Design Option"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)

    for key <- ["round-bar", "inline", "drawer", "fourth"], file <- ["#{key}.html", "#{key}.png"] do
      File.write!(Path.join(dir, file), "<html>#{key}</html>")
    end

    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task, dir: dir, option: %{"key" => "round-bar", "title" => "Round bar above the diff", "summary" => "A bar."}}
  end

  test "an option with its page and screenshot is added to the manifest and broadcast", %{
    task: %{id: task_id} = task,
    option: option
  } do
    assert {:ok, %{key: "round-bar", title: "Round bar above the diff", good_at: [], html: "<html>round-bar</html>"}} =
             Pipeline.save_design_option(task, option)

    assert %{options: [%{key: "round-bar"}], picked: nil} = Pipeline.read_design(task)
    assert_received {:output_saved, ^task_id}
  end

  test "an option saved after the plan was sent takes it back from the tech leads and tells Overview", %{
    task: %{id: task_id} = task,
    option: option
  } do
    Repo.insert!(%Round{task_id: task_id, number: 1, plan: "A plan.", ready_at: DateTime.utc_now()})
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    assert {:ok, %{key: "round-bar"}} = Pipeline.save_design_option(task, option)

    assert %Round{ready_at: nil, ready_by_id: nil} = Pipeline.read_plan(task)
    assert_received {:pipeline_changed, ^task_id}
  end

  test "an option saved on an approved plan leaves its send as it was", %{task: %{id: task_id} = task, option: option} do
    sent_at = ~U[2026-01-01 10:00:00.000000Z]
    Repo.insert!(%Round{task_id: task_id, number: 1, plan: "A plan.", ready_at: sent_at, approved_at: sent_at})

    assert {:ok, %{key: "round-bar"}} = Pipeline.save_design_option(task, option)

    assert %Round{ready_at: ^sent_at} = Pipeline.read_plan(task)
  end

  test "an option without its page or screenshot is refused naming each", %{task: task, dir: dir, option: option} do
    File.rm!(Path.join(dir, "inline.html"))
    File.rm!(Path.join(dir, "inline.png"))

    assert {:error, changeset} = Pipeline.save_design_option(task, %{option | "key" => "inline"})
    assert %{page: [page], screenshot: [screenshot]} = errors_on(changeset)
    assert page =~ "inline.html does not exist yet"
    assert screenshot =~ "inline.png does not exist yet"
    assert Pipeline.read_design(task) == nil
  end

  test "a bad key or a blank title is refused", %{task: task, option: option} do
    assert {:error, changeset} = Pipeline.save_design_option(task, %{option | "key" => "Round Bar", "title" => " "})
    assert %{key: ["must be lowercase letters, digits and dashes"], title: ["can't be blank"]} = errors_on(changeset)
  end

  test "saving a key again updates it in place", %{task: task, option: option} do
    {:ok, _first} = Pipeline.save_design_option(task, option)
    {:ok, _inline} = Pipeline.save_design_option(task, %{option | "key" => "inline", "title" => "Inline"})

    assert {:ok, %{title: "Renamed", costs: ["44px"]}} =
             Pipeline.save_design_option(task, Map.merge(option, %{"title" => "Renamed", "costs" => ["44px"]}))

    assert %{options: [%{key: "round-bar", title: "Renamed"}, %{key: "inline"}]} = Pipeline.read_design(task)
  end

  test "a fourth key before a pick is added after the first three, which stay as they were", %{
    task: task,
    option: option
  } do
    for key <- ["round-bar", "inline", "drawer"],
        do: {:ok, _saved} = Pipeline.save_design_option(task, %{option | "key" => key, "title" => "Title #{key}"})

    assert {:ok, %{key: "fourth", title: "Round bar with inline drafts"}} =
             Pipeline.save_design_option(task, %{option | "key" => "fourth", "title" => "Round bar with inline drafts"})

    assert %{
             options: [
               %{key: "round-bar", title: "Title round-bar"},
               %{key: "inline", title: "Title inline"},
               %{key: "drawer", title: "Title drawer"},
               %{key: "fourth", title: "Round bar with inline drafts"}
             ],
             picked: nil
           } = Pipeline.read_design(task)
  end

  test "after a pick from four options every other key is refused, a new one too", %{
    task: task,
    dir: dir,
    option: option
  } do
    for key <- ["round-bar", "inline", "drawer", "fourth"],
        do: {:ok, _saved} = Pipeline.save_design_option(task, %{option | "key" => key})

    File.write!(Path.join(dir, "picked"), "fourth")
    File.write!(Path.join(dir, "fifth.html"), "<html>fifth</html>")
    File.write!(Path.join(dir, "fifth.png"), "png")

    for key <- ["round-bar", "inline", "drawer", "fifth"] do
      assert {:error, changeset} = Pipeline.save_design_option(task, %{option | "key" => key})
      assert %{key: ["is not the picked option fourth, the only one that can be saved now"]} = errors_on(changeset)
    end

    assert {:ok, %{key: "fourth"}} = Pipeline.save_design_option(task, %{option | "key" => "fourth"})
  end

  test "after a pick only the picked key can be saved", %{task: task, dir: dir, option: option} do
    {:ok, _saved} = Pipeline.save_design_option(task, option)
    File.write!(Path.join(dir, "picked"), "round-bar")

    assert {:error, changeset} = Pipeline.save_design_option(task, %{option | "key" => "inline"})
    assert %{key: ["is not the picked option round-bar, the only one that can be saved now"]} = errors_on(changeset)

    assert {:ok, %{key: "round-bar", summary: "Refined."}} =
             Pipeline.save_design_option(task, %{option | "summary" => "Refined."})
  end

  test "an entry in the manifest that is not an object is dropped on the rewrite", %{task: task, dir: dir, option: option} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": ["junk", {"key": "inline", "title": "Inline"}]}))

    assert {:ok, _saved} = Pipeline.save_design_option(task, option)

    assert %{"options" => [%{"key" => "inline"}, %{"key" => "round-bar"}]} =
             dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end
end

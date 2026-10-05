defmodule Rail.Pipeline.Actions.SaveDesignOptionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline

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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Design Option"})
    {:ok, task} = Pipeline.create_task(issue, :design)
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

  test "a fourth key before a pick is refused", %{task: task, option: option} do
    for key <- ["round-bar", "inline", "drawer"],
        do: {:ok, _saved} = Pipeline.save_design_option(task, %{option | "key" => key})

    assert {:error, changeset} = Pipeline.save_design_option(task, %{option | "key" => "fourth"})
    assert %{key: ["would be a fourth option; save again under round-bar, inline, drawer"]} = errors_on(changeset)
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

defmodule Rail.Pipeline.Actions.ReadDesignTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_design_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "design"))
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{scratch_path: scratch}, design_dir: Path.join(scratch, "design")}
  end

  test "no manifest is no design", %{task: task} do
    assert Pipeline.read_design(task) == nil
  end

  test "a manifest that is not JSON, or has no list of options, is no design", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), "{not json")
    assert Pipeline.read_design(task) == nil

    File.write!(Path.join(dir, "manifest.json"), ~s({"options": "three"}))
    assert Pipeline.read_design(task) == nil
  end

  test "reads each option with its page, and skips the ones it cannot name", %{task: task, design_dir: dir} do
    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{
        "options" => [
          %{
            "key" => "cards",
            "title" => " Cards ",
            "summary" => " Big tiles. ",
            "good_at" => ["Easy to scan", " ", 3],
            "costs" => ["Few per screen"],
            "assumptions" => " Twelve per page. "
          },
          %{"key" => "table", "title" => "Table", "notes" => "Written before summaries."},
          %{"key" => "../escape", "title" => "Escape"},
          %{"key" => "untitled", "title" => "  "},
          "not an option"
        ]
      })
    )

    File.write!(Path.join(dir, "cards.html"), "<h1>Cards</h1>")
    File.write!(Path.join(dir, "cards.png"), "png")
    File.touch!(Path.join(dir, "cards.png"), 1_900_000_000)
    html_path = Path.join(dir, "cards.html")
    screenshot_path = Path.join(dir, "cards.png")

    assert %{
             picked: nil,
             options: [
               %{
                 key: "cards",
                 title: "Cards",
                 summary: "Big tiles.",
                 good_at: ["Easy to scan"],
                 costs: ["Few per screen"],
                 assumptions: "Twelve per page.",
                 html: "<h1>Cards</h1>",
                 html_path: ^html_path,
                 screenshot_path: ^screenshot_path,
                 screenshot_version: 1_900_000_000
               },
               %{
                 key: "table",
                 title: "Table",
                 summary: "Written before summaries.",
                 good_at: [],
                 costs: [],
                 assumptions: "",
                 html: nil,
                 screenshot_version: nil
               }
             ]
           } = Pipeline.read_design(task)
  end

  test "a pick counts only when it names an option", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))

    File.write!(Path.join(dir, "picked"), "table\n")
    assert %{picked: nil} = Pipeline.read_design(task)

    File.write!(Path.join(dir, "picked"), "cards\n")
    assert %{picked: "cards"} = Pipeline.read_design(task)
  end
end

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

  test "an option's page version follows its content", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    assert %{options: [%{html_version: nil}]} = Pipeline.read_design(task)

    File.write!(Path.join(dir, "cards.html"), "<h1>Cards</h1>")
    assert %{options: [%{html_version: written}]} = Pipeline.read_design(task)
    assert written =~ ~r/\A[\w-]{16}\z/

    File.write!(Path.join(dir, "cards.html"), "<h1>Cards</h1>")
    assert %{options: [%{html_version: ^written}]} = Pipeline.read_design(task)

    File.write!(Path.join(dir, "cards.html"), "<h1>Cards, without the links</h1>")
    assert %{options: [%{html_version: revised}]} = Pipeline.read_design(task)
    assert revised =~ ~r/\A[\w-]{16}\z/
    assert revised != written
  end

  test "a pick counts only when it names an option", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))

    File.write!(Path.join(dir, "picked"), "table\n")
    assert %{picked: nil} = Pipeline.read_design(task)

    File.write!(Path.join(dir, "picked"), "cards\n")
    assert %{picked: "cards"} = Pipeline.read_design(task)
  end

  test "says when the pick was made, and skips reading the pages when asked", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(dir, "cards.html"), "<h1>Cards</h1>")

    assert %{picked: nil, picked_at: nil, options: [%{html: "<h1>Cards</h1>"}]} = Pipeline.read_design(task)

    File.write!(Path.join(dir, "picked"), "cards")
    File.touch!(Path.join(dir, "picked"), 1_900_000_000)

    assert %{picked: "cards", picked_at: ~U[2030-03-17 17:46:40Z], options: [%{html: nil, html_version: nil}]} =
             Pipeline.read_design(task, pages: false)
  end

  test "pairs the nth iOS screen with the nth Android screen, a row a state, and sees a web screen", %{
    task: task,
    design_dir: dir
  } do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))

    File.write!(Path.join(dir, "cards.html"), """
    <main data-screen="web">Web</main>
    <div data-screen="ios" data-state=" This month "></div>
    <div data-screen="android" data-state="This month, on Android"></div>
    <section><div data-screen="ios" data-state="No expenses"></div></section>
    """)

    assert %{
             options: [
               %{
                 web: true,
                 rows: [
                   %{state: "This month", ios: "ios-1", android: "android-1"},
                   %{state: "No expenses", ios: "ios-2", android: nil}
                 ]
               }
             ]
           } = Pipeline.read_design(task)
  end

  test "names a row from Android when iOS has no name, and leaves a row with neither unnamed", %{
    task: task,
    design_dir: dir
  } do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))

    File.write!(Path.join(dir, "cards.html"), """
    <div data-screen="ios" data-state="  "></div><div data-screen="ios"></div>
    <div data-screen="android" data-state="Empty"></div><div data-screen="android" data-state=""></div>
    <div data-screen="android" data-state="caf\xE9"></div>
    """)

    assert %{
             options: [
               %{
                 web: false,
                 rows: [
                   %{state: "Empty", ios: "ios-1", android: "android-1"},
                   %{state: nil, ios: "ios-2", android: "android-2"},
                   %{state: "caf\uFFFD", ios: nil, android: "android-3"}
                 ]
               }
             ]
           } = Pipeline.read_design(task)
  end

  test "counts a mark only where the browser would, with its value exactly", %{task: task, design_dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))

    File.write!(Path.join(dir, "cards.html"), """
    <template><div data-screen="ios"></div><div data-screen="web"></div></template>
    <!-- <div data-screen="android"></div> -->
    <div data-screen="IOS"></div><div data-screen="ios-mini"></div><div data-screen=" web"></div>
    <div data-screen="android" data-state="#{String.duplicate("a", 200)}"></div>
    """)

    long = String.duplicate("a", 120)

    assert %{options: [%{web: false, rows: [%{state: ^long, ios: nil, android: "android-1"}]}]} =
             Pipeline.read_design(task)
  end

  test "an unmarked page, a page that is no HTML, and an unwritten one have no screens, and rows stop at 20", %{
    task: task,
    design_dir: dir
  } do
    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "plain", "title": "Plain"}, {"key": "bytes", "title": "Bytes"}, {"key": "many", "title": "Many"}, {"key": "unwritten", "title": "Unwritten"}]})
    )

    File.write!(Path.join(dir, "plain.html"), "<h1>Cards</h1>")
    File.write!(Path.join(dir, "bytes.html"), <<0, 255, 1, 254>>)
    File.write!(Path.join(dir, "many.html"), String.duplicate(~s(<div data-screen="ios"></div>), 25))

    assert %{
             options: [
               %{key: "plain", web: false, rows: []},
               %{key: "bytes", web: false, rows: []},
               %{key: "many", rows: many},
               %{key: "unwritten", html: nil, web: false, rows: []}
             ]
           } = Pipeline.read_design(task)

    assert length(many) == 20
    assert %{options: [%{web: false, rows: []} | _rest]} = Pipeline.read_design(task, pages: false)
  end
end

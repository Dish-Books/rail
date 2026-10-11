defmodule Rail.Mcp.Utils.RunToolQaShotTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaShot

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_qa_shot_test", to_string(unique)])
    on_exit(fn -> File.rm_rf(scratch) end)

    stub_screenshot(page_png(:empty_list))

    %{task: %Task{id: "tsk_shot_#{unique}", scratch_path: scratch}}
  end

  # The reply carries the path a finding cites, never the picture itself.
  test "photographs the browser it names and says where it was saved", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "explorer-1", [{:existing, true} | _opts] -> {:ok, self()} end)

    assert {:ok, "Saved as shots/the-saved-bill-" <> _rest} =
             run_tool_qa_shot(task, %{"name" => "The saved bill", "browser" => "explorer-1"}, stage: :review_lead)

    assert [saved] = Path.wildcard(Path.join([task.scratch_path, "qa", "shots", "the-saved-bill-*.jpg"]))
    assert File.read!(saved) == "jpeg bytes"
  end

  # Each explorer has a browser of its own, so a shot from the lead's run says whose it is.
  test "a shot from the Review lead's run that names no browser is refused before any browser", %{task: task} do
    reject(Tools, :start_browser_session, 3)

    assert {:refused, "Pass `browser`, the name the lead gave you" <> _rest} =
             run_tool_qa_shot(task, %{"name" => "Signed in"}, stage: :review_lead)
  end

  # A blank picture from a browser nobody drove would read as evidence.
  test "a browser browser_connect never opened is refused and nothing is saved", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:error, :no_browser} end)

    assert {:refused, "No browser named `typo` on this task." <> _rest} =
             run_tool_qa_shot(task, %{"name" => "Signed in", "browser" => "typo"}, stage: :review_lead)

    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a shot without a name, or with one that is not text, is refused before any browser", %{task: task} do
    reject(Tools, :start_browser_session, 3)

    assert {:refused, "qa_shot needs a `name`" <> _rest} = run_tool_qa_shot(task, %{}, stage: :review_lead)
    assert {:refused, "qa_shot needs a `name`" <> _rest} = run_tool_qa_shot(task, %{"name" => 42}, stage: :review_lead)
  end

  test "a page the browser cannot photograph is an error, not a picture", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)
    stub_screenshot("not a picture")

    assert {:error, :unreadable_screenshot} =
             run_tool_qa_shot(task, %{"name" => "Blank", "browser" => "explorer-1"}, stage: :review_lead)
  end

  # The explorer hears at once, so it retakes before the lead ever sees a blank picture.
  test "a picture all one color is refused and nothing is saved", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)
    stub_screenshot(page_png(:flat))

    assert {:refused, "Refused, nothing saved. The picture came back all one color" <> said} =
             run_tool_qa_shot(task, %{"name" => "The saved bill", "browser" => "explorer-1"}, stage: :review_lead)

    assert said =~ "report that with its URL and the steps that reach it, as text"
    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a width is the width the page is laid out at for the picture", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    expect(Tools, :capture_browser_evidence, fn _session, ^task, "Bill list at 768", [width: 768] ->
      {:ok, "shots/bill-list-at-768-1.jpg"}
    end)

    assert {:ok, "Saved as shots/bill-list-at-768-1.jpg. Read it now" <> _rest} =
             run_tool_qa_shot(task, %{"name" => "Bill list at 768", "browser" => "explorer-1", "width" => 768},
               stage: :review_lead
             )
  end

  test "a width outside 320 to 1920, or not a whole number, is refused before any browser", %{task: task} do
    reject(Tools, :start_browser_session, 3)

    for width <- [319, 1921, 1024.0, "1024"] do
      assert {:refused, "`width` is the width to lay the page out at" <> _rest} =
               run_tool_qa_shot(task, %{"name" => "Narrow", "browser" => "explorer-1", "width" => width},
                 stage: :review_lead
               )
    end
  end
end

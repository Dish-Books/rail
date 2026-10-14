defmodule Rail.Mcp.Utils.RunToolQaShotTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaShot

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_qa_shot_test", to_string(unique)])
    on_exit(fn -> File.rm_rf(scratch) end)

    # A blank tab all one white, and Rail's Learnings with nothing to review, which is sparse but not blank.
    flat = File.read!("test/support/fixtures/flat_page.png")
    empty_list = File.read!("test/support/fixtures/empty_list_page.png")
    viewport = %{"pageX" => 0, "pageY" => 0, "clientWidth" => 1920, "clientHeight" => 1080, "scale" => 1}

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, "Page.captureScreenshot", %{format: "png"} -> {:ok, %{"data" => Base.encode64(empty_list)}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    %{task: %Task{id: "tsk_shot_#{unique}", scratch_path: scratch}, flat: flat, viewport: viewport}
  end

  # The reply carries the path a finding cites, never the picture itself.
  test "photographs the browser it names and says where it was saved", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "explorer-1", [{:existing, true} | _opts] -> {:ok, self()} end)

    assert {:ok, "Saved as shots/the-saved-bill-" <> said} =
             run_tool_qa_shot(task, %{"name" => "The saved bill", "browser" => "explorer-1"}, stage: :qa)

    refute said =~ "back at its own width"

    assert [saved] = Path.wildcard(Path.join([task.scratch_path, "qa", "shots", "the-saved-bill-*.jpg"]))
    assert File.read!(saved) == "jpeg bytes"
  end

  # Each agent that drives the app has a browser of its own, named for its part.
  test "a shot that names no browser photographs QA's own", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "qa", [{:existing, false} | _opts] -> {:ok, self()} end)

    assert {:ok, "Saved as shots/signed-in-" <> _said} = run_tool_qa_shot(task, %{"name" => "Signed in"}, stage: :qa)
  end

  # A blank picture from a browser nobody drove would read as evidence.
  test "a browser browser_connect never opened is refused and nothing is saved", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:error, :no_browser} end)

    assert {:refused, "No browser named `typo` on this task." <> _rest} =
             run_tool_qa_shot(task, %{"name" => "Signed in", "browser" => "typo"}, stage: :qa)

    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a shot without a name, or with one that is not text, is refused before any browser", %{task: task} do
    reject(Tools, :start_browser_session, 3)

    assert {:refused, "qa_shot needs a `name`" <> _rest} = run_tool_qa_shot(task, %{}, stage: :qa)
    assert {:refused, "qa_shot needs a `name`" <> _rest} = run_tool_qa_shot(task, %{"name" => 42}, stage: :qa)
  end

  test "a page the browser cannot photograph is an error, not a picture", %{task: task, viewport: viewport} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64("not a picture")}}
    end)

    assert {:error, :unreadable_screenshot} =
             run_tool_qa_shot(task, %{"name" => "Blank", "browser" => "explorer-1"}, stage: :qa)
  end

  # The explorer hears at once, so it retakes before the lead ever sees a blank picture.
  test "a picture all one color is refused and nothing is saved", %{task: task, flat: flat, viewport: viewport} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64(flat)}}
    end)

    assert {:refused, "Refused, nothing saved. The picture came back all one color" <> said} =
             run_tool_qa_shot(task, %{"name" => "The saved bill", "browser" => "explorer-1"}, stage: :qa)

    assert said =~ "report that with its URL and the steps that reach it, as text"
    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a width is the width the page is laid out at for the picture", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    expect(Tools, :capture_browser_evidence, fn _session, ^task, "Bill list at 768", [width: 768] ->
      {:ok, "shots/bill-list-at-768-1.jpg"}
    end)

    assert {:ok, "Saved as shots/bill-list-at-768-1.jpg. Read it now" <> said} =
             run_tool_qa_shot(task, %{"name" => "Bill list at 768", "browser" => "explorer-1", "width" => 768},
               stage: :qa
             )

    # Clearing Rail's width also ends one an explorer's script set, which the script then has to set again.
    assert said =~ "The tab is back at its own width now, so a script holding a resize has to set it again."
  end

  test "a width of nil is the tab's own width", %{task: task} do
    stub(Tools, :start_browser_session, fn _task, _name, _opts -> {:ok, self()} end)

    expect(Tools, :capture_browser_evidence, fn _session, ^task, "Bill list", [width: nil] ->
      {:ok, "shots/bill-list-1.jpg"}
    end)

    assert {:ok, "Saved as shots/bill-list-1.jpg. Read it now" <> _rest} =
             run_tool_qa_shot(task, %{"name" => "Bill list", "browser" => "explorer-1", "width" => nil}, stage: :qa)
  end

  test "a width outside 320 to 1920, or not a whole number, is refused before any browser", %{task: task} do
    reject(Tools, :start_browser_session, 3)

    for width <- [319, 1921, 1024.0, "1024"] do
      assert {:refused, "`width` is the width to lay the page out at" <> _rest} =
               run_tool_qa_shot(task, %{"name" => "Narrow", "browser" => "explorer-1", "width" => width}, stage: :qa)
    end
  end
end

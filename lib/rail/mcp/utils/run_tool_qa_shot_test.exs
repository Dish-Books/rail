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

    stub(BrowserSession, :call, fn _session, "Page.captureScreenshot", _params ->
      {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

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
    stub(BrowserSession, :call, fn _session, _method, _params -> {:ok, %{"data" => "not base64 at all!"}} end)

    assert {:error, :unreadable_screenshot} =
             run_tool_qa_shot(task, %{"name" => "Blank", "browser" => "explorer-1"}, stage: :review_lead)
  end
end

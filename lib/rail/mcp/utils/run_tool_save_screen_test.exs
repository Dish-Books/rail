defmodule Rail.Mcp.Utils.RunToolSaveScreenTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RSS-1", :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

    # A blank tab all one white, and Rail's Learnings with nothing to review, which is sparse but not blank.
    flat = File.read!("test/support/fixtures/flat_page.png")
    empty_list = File.read!("test/support/fixtures/empty_list_page.png")
    viewport = %{"pageX" => 0, "pageY" => 0, "clientWidth" => 1920, "clientHeight" => 1080, "scale" => 1}

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, "Page.captureScreenshot", %{format: "png"} -> {:ok, %{"data" => Base.encode64(empty_list)}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    context = %RunContext{role: qa, os_process: %OsProcess{task_id: task.id}}

    %{
      task: task,
      worktree: worktree,
      context: context,
      head: worktree |> git!(["rev-parse", "HEAD"]) |> String.trim(),
      flat: flat,
      viewport: viewport
    }
  end

  test "photographs the named browser as the state's image for HEAD's commit", %{
    task: task,
    context: context,
    head: head
  } do
    expect(Tools, :start_browser_session, fn _task, "explorer-1", [{:existing, true} | _opts] -> {:ok, self()} end)
    short = String.slice(head, 0, 7)

    assert {:ok, %{"content" => [%{"text" => "Saved as screens/file-list/" <> said}]}} =
             Mcp.call_run_tool(context, "save_screen", %{
               "key" => "file-list",
               "label" => " File list just after Send ",
               "browser" => "explorer-1"
             })

    assert said =~ ".jpg, the image of file-list on #{short}."
    refute said =~ "back at its own width"

    assert [%{key: "file-list", label: "File list just after Send", commit: ^head, browser: "explorer-1"}] =
             Pipeline.list_screens(task)
  end

  test "a second save of a state replaces the first", %{task: task, context: context} do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)
    arguments = %{"key" => "file-list", "label" => "File list", "browser" => "explorer-1"}

    assert {:ok, _first} = Mcp.call_run_tool(context, "save_screen", arguments)

    assert {:ok, %{"content" => [%{"text" => "Saved as " <> said}]}} =
             Mcp.call_run_tool(context, "save_screen", %{arguments | "label" => "File list again"})

    [file, _rest] = String.split(said, ", the image", parts: 2)

    assert [%{key: "file-list", label: "File list again", file: ^file}] = Pipeline.list_screens(task)
    assert [_picture, _record] = File.ls!(Path.join([task.scratch_path, "qa", "screens", "file-list"]))
  end

  # Screens keeps showing the last good picture rather than a blank one.
  test "a picture all one color is refused and the state keeps its earlier picture", %{
    task: task,
    context: context,
    flat: flat,
    viewport: viewport
  } do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)
    arguments = %{"key" => "file-list", "label" => "File list", "browser" => "explorer-1"}

    assert {:ok, _first} = Mcp.call_run_tool(context, "save_screen", arguments)
    assert [%{key: "file-list", label: "File list", file: file}] = Pipeline.list_screens(task)

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64(flat)}}
    end)

    assert {:error, {:refused, "Refused, nothing saved. The picture came back all one color" <> _rest}} =
             Mcp.call_run_tool(context, "save_screen", %{arguments | "label" => "File list again"})

    assert [%{key: "file-list", label: "File list", file: ^file}] = Pipeline.list_screens(task)
    assert File.exists?(Path.join([task.scratch_path, "qa", file]))
  end

  # A state never saved has no picture to keep, so the refusal must not promise one.
  test "a picture all one color of a state never saved is refused without a picture it keeps", %{
    task: task,
    context: context,
    flat: flat,
    viewport: viewport
  } do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64(flat)}}
    end)

    assert {:error, {:refused, "Refused, nothing saved." <> said}} =
             Mcp.call_run_tool(context, "save_screen", %{
               "key" => "file-list",
               "label" => "File list",
               "browser" => "explorer-1"
             })

    refute said =~ "keeps its last picture"
    assert [] = Pipeline.list_screens(task)
  end

  test "a width is the width the state is laid out at for its picture", %{context: context} do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)

    expect(Tools, :capture_browser_evidence, fn _session, _task, "File list", [key: "file-list", width: 390] ->
      {:ok, "screens/file-list/1.jpg"}
    end)

    assert {:ok, %{"content" => [%{"text" => "Saved as screens/file-list/1.jpg" <> said}]}} =
             Mcp.call_run_tool(context, "save_screen", %{
               "key" => "file-list",
               "label" => "File list",
               "browser" => "explorer-1",
               "width" => 390
             })

    # Clearing Rail's width also ends one an explorer's script set, which the script then has to set again.
    assert said =~ "The tab is back at its own width now, so a script holding a resize has to set it again."
  end

  test "a width of nil is the tab's own width", %{context: context} do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)

    expect(Tools, :capture_browser_evidence, fn _session, _task, "File list", [key: "file-list", width: nil] ->
      {:ok, "screens/file-list/1.jpg"}
    end)

    assert {:ok, %{"content" => [%{"text" => "Saved as screens/file-list/1.jpg" <> _rest}]}} =
             Mcp.call_run_tool(context, "save_screen", %{
               "key" => "file-list",
               "label" => "File list",
               "browser" => "explorer-1",
               "width" => nil
             })
  end

  test "a page the browser cannot photograph is an error and saves no picture", %{
    task: task,
    context: context,
    viewport: viewport
  } do
    stub(Tools, :start_browser_session, fn _task, "explorer-1", _opts -> {:ok, self()} end)

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params -> {:ok, %{"cssVisualViewport" => viewport}}
      _session, _method, _params -> {:ok, %{"data" => Base.encode64("not a picture")}}
    end)

    assert {:error, _unreadable} =
             Mcp.call_run_tool(context, "save_screen", %{
               "key" => "file-list",
               "label" => "File list",
               "browser" => "explorer-1"
             })

    assert [] = Pipeline.list_screens(task)
  end

  # A picture of uncommitted work belongs to no commit, so it could never say which one it shows.
  test "a worktree with uncommitted changes is refused before any browser", %{context: context, worktree: worktree} do
    File.write!(Path.join(worktree, "wip.ex"), "uncommitted\n")
    reject(Tools, :start_browser_session, 3)

    assert {:error, {:refused, "Refused, nothing saved. The worktree has uncommitted changes" <> _rest}} =
             Mcp.call_run_tool(context, "save_screen", %{"key" => "file-list", "label" => "File list", "browser" => "x"})
  end

  test "a key, label or browser Rail will not take is refused before any picture", %{context: context, task: task} do
    reject(Tools, :start_browser_session, 3)

    for {arguments, said} <- [
          {%{"key" => "../up", "label" => "x"}, "`key` is the state's name"},
          {%{"key" => "Toolbar", "label" => "x"}, "`key` is the state's name"},
          {%{"key" => "toolbar", "label" => "  "}, "`label` says what the state shows"},
          {%{"key" => "toolbar", "label" => String.duplicate("x", 121)}, "`label` says what the state shows"},
          {%{"key" => "toolbar", "label" => "Toolbar", "width" => 200}, "`width` is the width to lay the page out at"},
          {%{"key" => "toolbar", "label" => "Toolbar", "width" => 768.5}, "`width` is the width to lay the page out at"},
          {%{"key" => "toolbar"}, "save_screen needs the state's `key` and a `label`"},
          {%{"key" => "toolbar", "label" => "Toolbar", "browser" => "a/b"}, "`browser` is a name"}
        ] do
      assert {:error, {:refused, refused}} = Mcp.call_run_tool(context, "save_screen", arguments)
      assert refused =~ said
    end

    assert [] = Pipeline.list_screens(task)
  end

  test "a worktree that is gone is refused", %{context: context, task: task} do
    {:ok, _gone} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {:error, {:refused, "Refused, nothing saved. The worktree has uncommitted changes" <> _rest}} =
             Mcp.call_run_tool(context, "save_screen", %{"key" => "toolbar", "label" => "Toolbar", "browser" => "x"})
  end
end

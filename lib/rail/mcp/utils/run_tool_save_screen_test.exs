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
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    stub(BrowserSession, :call, fn _session, "Page.captureScreenshot", _params ->
      {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    context = %RunContext{role: lead, os_process: %OsProcess{task_id: task.id}}

    %{task: task, worktree: worktree, context: context, head: worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()}
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

    assert [%{key: "file-list", label: "File list just after Send", shots: [%{commit: ^head, browser: "explorer-1"}]}] =
             Pipeline.list_screens(task)
  end

  # A picture of uncommitted work belongs to no commit, so it could never be set beside one.
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
          {%{"key" => "toolbar"}, "save_screen needs the state's `key` and a `label`"},
          {%{"key" => "toolbar", "label" => "Toolbar"}, "Pass `browser`"}
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

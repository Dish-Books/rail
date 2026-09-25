defmodule Rail.Tools.Actions.ObserveBrowserTest do
  use Rail.DataCase, async: false

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  # Serial, because each test drives a real Chrome and a machine running thirty at
  # once measures contention rather than the browser.
  @moduletag :browser

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_obb_#{System.unique_integer([:positive])}",
              "identifier" => "OBB-1",
              "title" => "Observe Browser"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Observe Browser"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(task.scratch_path)

    page = Path.join(task.scratch_path, "bill.html")

    File.write!(page, """
    <!doctype html><title>New bill</title>
    <h1>New bill</h1>
    <label for="amount">Amount</label><input id="amount" type="text" value="1234.50">
    <label for="due">Due date</label><input id="due" type="date" value="2026-09-19">
    <button type="button" id="save">Save</button>
    """)

    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: "file://#{page}"})

    # `Page.navigate` answers before the document exists, and a slow machine is still loading when the test starts.
    eventually(fn -> assert {:ok, %{"title" => "New bill"}} = Tools.observe_browser(session) end, 5_000)

    # Killing the process rather than going through `stop_browser_session/1`: an
    # `on_exit` runs in a process of its own with no sandbox connection, and the
    # row it would settle is rolled back with the test anyway. What must not
    # survive is the Chrome.
    on_exit(fn ->
      case Tools.get_browser_session(task) do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
        nil -> :ok
      end

      File.rm_rf(task.scratch_path)
    end)

    %{task: task, session: session}
  end

  test "reads where it is, what it says and what can be done to it", %{session: session} do
    assert {:ok, page} = Tools.observe_browser(session)

    assert page["title"] == "New bill"
    assert page["text"] =~ "New bill"
    assert Enum.any?(page["actions"], &(&1["label"] == "Save"))
    refute Map.has_key?(page, "screenshot")

    # A field the snapshot leaves out is a field nothing can be asked to fill,
    # which is how a whole screen came back as "nothing on this page can carry
    # that out".
    assert %{"kind" => "fill", "picker" => true, "value" => "2026-09-19"} =
             Enum.find(page["actions"], &(&1["label"] == "Due date" and &1["kind"] == "fill"))
  end

  # Two observations of a page nobody touched are the same page, and one action
  # is enough to make them different.
  test "the fingerprint changes only when the page does", %{session: session} do
    {:ok, first} = Tools.observe_browser(session)
    {:ok, again} = Tools.observe_browser(session)

    assert first["fingerprint"] == again["fingerprint"]

    {:ok, _typed} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression: "document.getElementById('amount').remove()",
        returnByValue: true
      })

    {:ok, changed} = Tools.observe_browser(session)

    assert changed["fingerprint"] != first["fingerprint"]
  end

  # Evidence is the page as it was read rather than as it was a moment later, so
  # the picture is taken inside the same observation.
  test "the page can be photographed as it is read", %{session: session} do
    assert {:ok, page} = Tools.observe_browser(session, screenshot: true)

    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Base.decode64(page["screenshot"])
  end

  # A document mid-navigation has nothing to read, and that is worth asking again
  # about in a moment - unlike anything else that comes back from here.
  test "a page that is navigating is worth asking about again", %{session: _session} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:ok, %{"result" => %{"value" => nil}}} end)

    assert {:error, :navigating} = Tools.observe_browser(:navigating)
  end

  test "a browser that will not answer says why", %{session: _session} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:error, "no such target"} end)

    assert {:error, "no such target"} = Tools.observe_browser(:gone)
  end

  # The picture is the part that can fail on its own, and a page that was read is
  # still worth having without it.
  test "a photograph that fails does not lose the reading", %{session: _session} do
    stub(BrowserSession, :call, fn
      _session, "Runtime.evaluate", _params -> {:ok, %{"result" => %{"value" => %{"url" => "about:blank"}}}}
      _session, "Page.captureScreenshot", _params -> {:error, "target closed"}
    end)

    assert {:ok, page} = Tools.observe_browser(:closing, screenshot: true)
    refute Map.has_key?(page, "screenshot")
  end
end

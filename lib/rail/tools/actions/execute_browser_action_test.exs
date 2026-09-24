defmodule Rail.Tools.Actions.ExecuteBrowserActionTest do
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
            "issue" => %{"id" => "lin_exa_1", "identifier" => "EXA-1", "title" => "Execute Action"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Execute Action"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(task.scratch_path)

    page = Path.join(task.scratch_path, "bill.html")

    File.write!(page, """
    <!doctype html><title>New bill</title>
    <h1 id="top">New bill</h1>
    <label for="amount">Amount</label><input id="amount" type="text" value="99">
    <label for="vendor">Vendor</label>
    <select id="vendor"><option value="">Pick one</option><option value="acme">Acme</option></select>
    <label for="due">Due date</label><input id="due" type="date">
    <label for="at">Posted at</label><input id="at" type="datetime-local">
    <button type="button" id="save" onclick="document.title = 'Saved ' + amount.value">Save</button>
    <label for="keys">Notes</label><input id="keys" value="" onkeydown="document.title = 'Key ' + event.key">
    <button type="button" id="wide" style="width: 400px" onclick="document.title = 'Wide'">Wide button</button>
    <div style="height: 4000px"></div>
    <p id="bottom">The end</p>
    """)

    {:ok, session} = Tools.start_browser_session(task)
    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: "file://#{page}"})

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

    # A document still navigating has nothing to read, which is exactly what
    # `observe_browser/2` says rather than raising - so wait for the page these
    # tests act on to be there.
    page =
      eventually(fn ->
        assert {:ok, %{"actions" => [_first | _rest]} = page} = Tools.observe_browser(session)

        page
      end)

    %{session: session, page: page}
  end

  # A click is dispatched as a real mouse event at the element's own centre, so
  # the handler a person would have triggered is the handler that runs.
  test "clicks the element a decision named", %{session: session, page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    assert {:ok, _executed} = Tools.execute_browser_action(session, save)

    assert {:ok, %{"result" => %{"value" => "Saved 99"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
  end

  # A field with something already in it is the ordinary case, and a check that
  # meant to enter 12 must not end up with 9912.
  test "typing replaces what the field held", %{session: session, page: page} do
    amount = Enum.find(page["actions"], &(&1["label"] == "Amount"))

    assert {:ok, _executed} = Tools.execute_browser_action(session, amount, "12")

    assert {:ok, %{"result" => %{"value" => "12"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "document.getElementById('amount').value",
               returnByValue: true
             })
  end

  # A dropdown is chosen while the element is still held rather than clicked at a
  # point, because the list a click opens is drawn by the operating system.
  test "a dropdown is set rather than clicked", %{session: session, page: page} do
    acme = Enum.find(page["actions"], &(&1["kind"] == "select" and &1["label"] =~ "Acme"))

    assert {:ok, _executed} = Tools.execute_browser_action(session, acme)

    assert {:ok, %{"result" => %{"value" => "acme"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "document.getElementById('vendor').value",
               returnByValue: true
             })
  end

  # The browser draws a date input as segments no keystroke reaches, so it is set
  # the way a dropdown is - and a page that only sees `.value` change is a page
  # that never knew, hence the events.
  test "a date is set rather than typed, and the page is told", %{session: session, page: page} do
    due = Enum.find(page["actions"], &(&1["label"] == "Due date" and &1["kind"] == "fill"))

    {:ok, _watching} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression:
          "window.__heard = []; due.addEventListener('input', () => __heard.push('input')); " <>
            "due.addEventListener('change', () => __heard.push('change'))",
        returnByValue: true
      })

    assert {:ok, _executed} = Tools.execute_browser_action(session, due, "2026-09-19")

    assert {:ok, %{"result" => %{"value" => ["2026-09-19", ["input", "change"]]}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{
               expression: "[due.value, window.__heard]",
               returnByValue: true
             })
  end

  test "a datetime is set the same way", %{session: session, page: page} do
    at = Enum.find(page["actions"], &(&1["label"] == "Posted at" and &1["kind"] == "fill"))

    assert {:ok, _executed} = Tools.execute_browser_action(session, at, "2026-09-19T14:30")

    assert {:ok, %{"result" => %{"value" => "2026-09-19T14:30"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "at.value", returnByValue: true})
  end

  # A date field takes the value the HTML gives it whatever the page displays, so
  # a value in the reader's format is refused rather than silently dropped.
  test "a date the browser will not take says so", %{session: session, page: page} do
    due = Enum.find(page["actions"], &(&1["label"] == "Due date" and &1["kind"] == "fill"))

    assert {:error, {:value_rejected, "19/09/2026"}} = Tools.execute_browser_action(session, due, "19/09/2026")

    assert {:ok, %{"result" => %{"value" => ""}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "due.value", returnByValue: true})
  end

  test "scrolling moves the page", %{session: session} do
    assert {:ok, _scrolled} = Tools.execute_browser_action(session, %{"kind" => "scroll", "id" => "scroll"})

    eventually(fn ->
      assert {:ok, %{"result" => %{"value" => moved}}} =
               BrowserSession.call(session, "Runtime.evaluate", %{expression: "scrollY", returnByValue: true})

      assert moved > 0
    end)
  end

  # Waiting is a thing a decision can ask for when a page is mid-render, and it
  # is the one action that does not touch the browser at all.
  test "waiting does nothing to the page", %{session: session} do
    assert {:ok, "wait"} = Tools.execute_browser_action(session, %{"kind" => "wait", "id" => "wait"})
  end

  # Nothing is ever invented, so a field with no value supplied is refused here
  # as well as by whoever was driving.
  test "a field with no value supplied is refused", %{session: session} do
    assert {:error, :no_text_to_type} = Tools.execute_browser_action(session, %{"kind" => "fill"}, nil)
  end

  test "an action that never came off a page is refused", %{session: session} do
    assert {:error, :not_an_observed_element} = Tools.execute_browser_action(session, %{"kind" => "invented"})
  end

  # The gap between reading a page and acting on it is real, and the whole point
  # of resolving again is that the element it names may be gone.
  test "an element that has left the page is refused, and says so", %{session: session, page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    {:ok, _removed} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression: "document.getElementById('save').remove()",
        returnByValue: true
      })

    assert {:error, {:refused, "gone", nil}} = Tools.execute_browser_action(session, save)
  end

  # Disabled, hidden, covered and gone are four different answers, and the one
  # about a control the page will not let anybody use is often the finding.
  test "a control the page has disabled is refused as disabled", %{session: session, page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    {:ok, _disabled} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression: "document.getElementById('save').disabled = true",
        returnByValue: true
      })

    assert {:error, {:refused, "disabled", nil}} = Tools.execute_browser_action(session, save)
  end

  # What is drawn over it is the part a person debugging this cannot work out
  # from a refusal on its own.
  test "a control something is drawn over names what took the click", %{session: session, page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    {:ok, _covered} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression: """
        const over = document.createElement('div');
        over.textContent = 'Saving';
        over.setAttribute('style', 'position:fixed;inset:0;background:white');
        document.body.appendChild(over);
        """,
        returnByValue: true
      })

    assert {:error, {:refused, "covered", ~s(div "Saving")}} = Tools.execute_browser_action(session, save)
  end

  # Committing a grid cell, closing a menu and leaving a field are all a key, and
  # none of them is a control that can be clicked. A driver without keys hunts for
  # something to click instead.
  test "a key reaches whatever holds focus", %{session: session, page: page} do
    keys = Enum.find(page["actions"], &(&1["label"] == "Notes" and &1["kind"] == "fill"))
    enter = Enum.find(page["actions"], &(&1["id"] == "press_enter"))

    assert %{"kind" => "press", "key" => "Enter"} = enter

    {:ok, _focused} = Tools.execute_browser_action(session, keys, "1234.56")

    assert {:ok, "press_enter"} = Tools.execute_browser_action(session, enter)

    assert {:ok, %{"result" => %{"value" => "Key Enter"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
  end

  test "escape and tab are offered too", %{page: page} do
    assert ["Escape", "Tab"] =
             page["actions"]
             |> Enum.filter(&(&1["kind"] == "press" and &1["key"] != "Enter"))
             |> Enum.map(& &1["key"])
             |> Enum.sort()
  end

  # A sticky bar across the middle of a wide control does not make it unclickable:
  # it is still reachable at either end, and refusing it sends whoever is driving
  # looking for another way to do something that was always possible.
  test "a control covered only in the middle is clicked where it is not", %{session: session, page: page} do
    wide = Enum.find(page["actions"], &(&1["label"] == "Wide button"))

    {:ok, _covered} =
      BrowserSession.call(session, "Runtime.evaluate", %{
        expression: """
        const bar = document.createElement('div');
        const r = document.getElementById('wide').getBoundingClientRect();
        bar.textContent = 'Bill total $0.00';
        bar.setAttribute('style',
          `position:fixed;left:${r.x + 60}px;top:${r.y - 4}px;width:120px;height:${r.height + 8}px;background:white`);
        document.body.appendChild(bar);
        """,
        returnByValue: true
      })

    assert {:ok, _executed} = Tools.execute_browser_action(session, wide)

    assert {:ok, %{"result" => %{"value" => "Wide"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
  end

  # Between reading the page and acting on it the page can move - a banner loads,
  # a toast pushes everything down, the reader scrolls. An element carried out of
  # view that way is one the page will happily show again if asked, rather than
  # one to refuse as off screen.
  test "an element the page scrolled away is scrolled back to", %{session: session, page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    {:ok, _moved} =
      BrowserSession.call(session, "Runtime.evaluate", %{expression: "scrollTo(0, 2000)", returnByValue: true})

    assert {:ok, _executed} = Tools.execute_browser_action(session, save)

    assert {:ok, %{"result" => %{"value" => "Saved 99"}}} =
             BrowserSession.call(session, "Runtime.evaluate", %{expression: "document.title", returnByValue: true})
  end

  # A form abandoned by following a link is only recoverable by going back, so
  # back is a thing the page offers like any other.
  test "goes back to where the browser came from", %{session: session} do
    second = Path.join(System.tmp_dir!(), "rail-back-#{System.unique_integer([:positive])}.html")
    File.write!(second, "<!doctype html><title>Sent</title>")
    on_exit(fn -> File.rm(second) end)

    {:ok, _navigated} = BrowserSession.call(session, "Page.navigate", %{url: "file://#{second}"})

    eventually(fn ->
      assert {:ok, %{"title" => "Sent"}} = Tools.observe_browser(session)
    end)

    assert {:ok, "back"} = Tools.execute_browser_action(session, %{"kind" => "back", "id" => "back"})

    eventually(fn ->
      assert {:ok, %{"title" => "New bill"}} = Tools.observe_browser(session)
    end)
  end

  test "a browser with nowhere to go back to says so", %{page: _page} do
    stub(BrowserSession, :call, fn _session, "Page.getNavigationHistory", _params ->
      {:ok, %{"currentIndex" => 0, "entries" => [%{"id" => 1}]}}
    end)

    assert {:error, {:refused, "nowhere to go back to", nil}} =
             Tools.execute_browser_action(:fresh, %{"kind" => "back", "id" => "back"})
  end

  test "a history entry that is not there says the same", %{page: _page} do
    stub(BrowserSession, :call, fn _session, "Page.getNavigationHistory", _params ->
      {:ok, %{"currentIndex" => 2, "entries" => [%{"id" => 1}]}}
    end)

    assert {:error, {:refused, "nowhere to go back to", nil}} =
             Tools.execute_browser_action(:fresh, %{"kind" => "back", "id" => "back"})
  end

  test "a browser that will not say where it has been reports that", %{page: _page} do
    stub(BrowserSession, :call, fn _session, "Page.getNavigationHistory", _params -> {:error, "no such target"} end)

    assert {:error, "no such target"} = Tools.execute_browser_action(:gone, %{"kind" => "back", "id" => "back"})
  end

  # Everything below drives a browser that answers badly rather than a real one,
  # because a page cannot be asked to fail on command and these are the answers
  # that decide whether a step is reported as done.
  # A resolve that answers with nothing at all is an element that is not there
  # any more, which is the same answer as saying so.
  test "a browser that answers nothing about the element reads as gone", %{page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    stub(BrowserSession, :call, fn _session, "Runtime.evaluate", _params -> {:ok, %{"result" => %{}}} end)

    assert {:error, {:refused, "gone", nil}} = Tools.execute_browser_action(:blank, save)
  end

  test "a browser that will not resolve the element says why", %{page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    stub(BrowserSession, :call, fn _session, _method, _params -> {:error, "no such target"} end)

    assert {:error, "no such target"} = Tools.execute_browser_action(:gone, save)
  end

  test "a click the browser refuses stops before anything is typed", %{page: page} do
    amount = Enum.find(page["actions"], &(&1["label"] == "Amount"))

    stub(BrowserSession, :call, fn
      _session, "Runtime.evaluate", _params -> {:ok, %{"result" => %{"value" => %{"x" => 1, "y" => 2}}}}
      _session, "Input.dispatchMouseEvent", _params -> {:error, "target closed"}
    end)

    assert {:error, "target closed"} = Tools.execute_browser_action(:closing, amount, "12")
  end

  # Waiting for the page to settle is worth doing and not worth failing over: an
  # action that navigated has taken the document the wait was written against
  # with it, and the action still happened.
  test "a page that navigated out from under the wait is still a step that landed", %{page: page} do
    save = Enum.find(page["actions"], &(&1["label"] == "Save"))

    stub(BrowserSession, :call, fn
      _session, "Runtime.evaluate", %{awaitPromise: true} -> {:error, "Execution context was destroyed"}
      _session, "Runtime.evaluate", _params -> {:ok, %{"result" => %{"value" => %{"x" => 1, "y" => 2}}}}
      _session, _method, _params -> {:ok, %{}}
    end)

    assert {:ok, _executed} = Tools.execute_browser_action(:navigating, save)
  end
end

defmodule Rail.Tools.Actions.SendBrowserInputTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  setup do
    task = %Task{id: UXID.generate!(prefix: "tsk")}
    # The test stands in for the tab's session, so what would go to Chrome comes to it.
    session = self()
    {:ok, _registered} = Registry.register(Rail.Tools.BrowserRegistry, {task.id, "app"}, nil)

    stub(BrowserSession, :cast, fn ^session, method, params ->
      send(session, {:cast, method, params})
      :ok
    end)

    %{task: task}
  end

  test "a click goes to the tab as Chrome's mouse event, with its button, count and modifiers", %{task: task} do
    event = %{"kind" => "mouse", "type" => "mousePressed", "x" => 12, "y" => 30.5, "button" => "left"}

    assert :ok = Tools.send_browser_input(task, "app", Map.merge(event, %{"click_count" => 2, "modifiers" => 8}))

    assert_received {:cast, "Input.dispatchMouseEvent",
                     %{type: "mousePressed", x: 12, y: 30.5, button: "left", buttons: 1, clickCount: 2, modifiers: 8}}
  end

  test "each button is held as Chrome counts it, and a move with none holds nothing", %{task: task} do
    for {button, buttons} <- [{"right", 2}, {"middle", 4}, {"none", 0}] do
      event = %{"kind" => "mouse", "type" => "mouseReleased", "x" => 1, "y" => 1, "button" => button}
      :ok = Tools.send_browser_input(task, "app", event)
      assert_received {:cast, "Input.dispatchMouseEvent", %{button: ^button, buttons: ^buttons}}
    end

    :ok = Tools.send_browser_input(task, "app", %{"kind" => "mouse", "type" => "mouseMoved", "x" => 5, "y" => 6})
    assert_received {:cast, "Input.dispatchMouseEvent", %{type: "mouseMoved", button: "none", buttons: 0}}
  end

  # The page sends what it likes, so a field out of range falls back to what Chrome takes as nothing.
  test "a button, count or modifiers Chrome would not take are sent as none, one and none", %{task: task} do
    event = %{
      "kind" => "mouse",
      "type" => "mousePressed",
      "x" => 1,
      "y" => 1,
      "button" => "back",
      "click_count" => 9,
      "modifiers" => 99
    }

    :ok = Tools.send_browser_input(task, "app", event)

    assert_received {:cast, "Input.dispatchMouseEvent", %{button: "none", buttons: 0, clickCount: 1, modifiers: 0}}
  end

  test "a wheel scrolls the tab where the pointer is", %{task: task} do
    event = %{"kind" => "wheel", "x" => 100, "y" => 200, "dx" => 0, "dy" => -120.5}

    assert :ok = Tools.send_browser_input(task, "app", event)

    assert_received {:cast, "Input.dispatchMouseEvent", %{type: "mouseWheel", x: 100, y: 200, deltaX: 0, deltaY: -120.5}}
  end

  test "a key that types carries its text, and Chrome's key code", %{task: task} do
    event = %{
      "kind" => "key",
      "type" => "keyDown",
      "key" => "Enter",
      "code" => "Enter",
      "key_code" => 13,
      "text" => "\r",
      "modifiers" => 2
    }

    assert :ok = Tools.send_browser_input(task, "app", event)

    assert_received {:cast, "Input.dispatchKeyEvent",
                     %{
                       type: "keyDown",
                       key: "Enter",
                       code: "Enter",
                       modifiers: 2,
                       windowsVirtualKeyCode: 13,
                       text: "\r",
                       unmodifiedText: "\r"
                     }}
  end

  test "a key that types nothing goes without text or a key code out of range", %{task: task} do
    event = %{"kind" => "key", "type" => "keyUp", "key" => "Shift", "code" => "ShiftLeft", "key_code" => 999}

    assert :ok = Tools.send_browser_input(task, "app", event)

    assert_received {:cast, "Input.dispatchKeyEvent", params}
    assert params == %{type: "keyUp", key: "Shift", code: "ShiftLeft", modifiers: 0}
  end

  test "text pasted or composed is inserted as it is", %{task: task} do
    assert :ok = Tools.send_browser_input(task, "app", %{"kind" => "text", "text" => "Crème brûlée"})
    assert_received {:cast, "Input.insertText", %{text: "Crème brûlée"}}
  end

  test "Reload reloads the tab and Back goes back in its history", %{task: task} do
    assert :ok = Tools.send_browser_input(task, "app", %{"kind" => "navigate", "to" => "reload"})
    assert_received {:cast, "Page.reload", %{}}

    assert :ok = Tools.send_browser_input(task, "app", %{"kind" => "navigate", "to" => "back"})
    assert_received {:cast, "Runtime.evaluate", %{expression: "history.back()"}}
  end

  test "an event of no shape it knows, or off the tab, is refused and nothing is sent", %{task: task} do
    for event <- [
          %{"kind" => "mouse", "type" => "mousePressed", "x" => -1, "y" => 10},
          %{"kind" => "mouse", "type" => "mousePressed", "x" => 10, "y" => 1081},
          %{"kind" => "mouse", "type" => "mousePressed", "x" => "10", "y" => 10},
          %{"kind" => "mouse", "type" => "dragStart", "x" => 10, "y" => 10},
          %{"kind" => "wheel", "x" => 2000, "y" => 10, "dx" => 0, "dy" => 1},
          %{"kind" => "wheel", "x" => 10, "y" => 10, "dx" => "0", "dy" => 1},
          %{"kind" => "key", "type" => "keyPress", "key" => "a", "code" => "KeyA"},
          %{"kind" => "text", "text" => ""},
          %{"kind" => "navigate", "to" => "https://example.com"},
          %{"kind" => "eval", "expression" => "alert(1)"}
        ] do
      assert {:error, :invalid_input} = Tools.send_browser_input(task, "app", event)
    end

    refute_received {:cast, _method, _params}
  end

  test "a tab that is not open is said to be so", %{task: task} do
    assert {:error, :no_browser} =
             Tools.send_browser_input(task, "qa", %{"kind" => "navigate", "to" => "reload"})
  end
end

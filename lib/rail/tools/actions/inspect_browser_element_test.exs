defmodule Rail.Tools.Actions.InspectBrowserElementTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  setup do
    task = %Task{id: UXID.generate!(prefix: "tsk")}
    # The test stands in for the tab's session; what Chrome answers is stubbed per test.
    {:ok, _registered} = Registry.register(Rail.Tools.BrowserRegistry, {task.id, "app"}, nil)
    dir = Path.join(System.tmp_dir!(), "inspect_element_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    element = %{
      "selector" => "#checkout > button:nth-child(2)",
      "text" => "Pay now",
      "tag" => "button",
      "html" => ~s(<button class="pay">Pay now</button>),
      "x" => 1880,
      "y" => 8,
      "width" => 120,
      "height" => 40,
      "url" => "http://localhost:20650/checkout?step=2"
    }

    %{task: task, dir: dir, element: element}
  end

  test "describes the element under the point and saves a picture of it with a margin, kept on the tab", %{
    task: task,
    dir: dir,
    element: element
  } do
    session = self()

    stub(BrowserSession, :call, fn
      ^session, "Runtime.evaluate", %{expression: expression, returnByValue: true} ->
        assert String.ends_with?(expression, "(1900, 20)")
        {:ok, %{"result" => %{"type" => "object", "value" => element}}}

      ^session, "Page.captureScreenshot", %{format: "jpeg", clip: clip} ->
        assert clip == %{x: 1864, y: 0, width: 56, height: 64, scale: 1}
        {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    assert {:ok,
            %{
              selector: "#checkout > button:nth-child(2)",
              text: "Pay now",
              tag: "button",
              html: ~s(<button class="pay">Pay now</button>),
              x: 1880,
              y: 8,
              width: 120,
              height: 40,
              url: "http://localhost:20650/checkout?step=2",
              picture: picture
            }} = Tools.inspect_browser_element(task, "app", 1900, 20, dir)

    assert Path.dirname(picture) == dir
    assert Path.extname(picture) == ".jpg"
    assert File.read!(picture) == "jpeg bytes"
  end

  test "a point with no element under it is said so, and nothing is photographed", %{task: task, dir: dir} do
    stub(BrowserSession, :call, fn _session, "Runtime.evaluate", _params ->
      {:ok, %{"result" => %{"type" => "object", "subtype" => "null", "value" => nil}}}
    end)

    assert {:error, :no_element} = Tools.inspect_browser_element(task, "app", 5, 5, dir)
    refute File.exists?(dir)
  end

  test "says what Chrome said when it cannot photograph the element", %{task: task, dir: dir, element: element} do
    stub(BrowserSession, :call, fn
      _session, "Runtime.evaluate", _params -> {:ok, %{"result" => %{"value" => element}}}
      _session, "Page.captureScreenshot", _params -> {:error, %{"message" => "Target closed"}}
    end)

    assert {:error, %{"message" => "Target closed"}} = Tools.inspect_browser_element(task, "app", 5, 5, dir)
  end

  test "a tab that is not open is said to be so", %{task: task, dir: dir} do
    assert {:error, :no_browser} = Tools.inspect_browser_element(task, "qa", 5, 5, dir)
  end
end

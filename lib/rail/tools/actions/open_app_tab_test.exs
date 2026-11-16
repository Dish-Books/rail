defmodule Rail.Tools.Actions.OpenAppTabTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  setup do
    task = %Task{id: UXID.generate!(prefix: "tsk")}
    # The test stands in for the tab's session, so what would go to Chrome comes to it.
    {:ok, _registered} = Registry.register(Rail.Tools.BrowserRegistry, {task.id, "app"}, nil)
    cookie = %{name: "CF_Authorization", value: "jwt", domain: "pr-7.preview.example.com", path: "/"}

    %{task: task, cookie: cookie}
  end

  # The cookie is in the tab's context before the page is asked for, so Access lets the first request through.
  test "sets each cookie in the tab, then opens the address signed in", %{task: task, cookie: cookie} do
    session = self()

    expect(BrowserSession, :call, fn ^session, "Network.setCookie", ^cookie ->
      send(session, :cookie_set)
      {:ok, %{"success" => true}}
    end)

    expect(BrowserSession, :sign_in, fn ^session, "https://pr-7.preview.example.com/dev/login", nil ->
      assert_received :cookie_set
      :ok
    end)

    assert :ok = Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/dev/login", [cookie])
  end

  test "without cookies the address is opened straight away", %{task: task} do
    reject(BrowserSession, :call, 3)
    expect(BrowserSession, :sign_in, fn _session, "https://pr-7.preview.example.com/", nil -> :ok end)

    assert :ok = Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/", [])
  end

  test "a cookie Chrome refuses, or cannot be asked to set, opens nothing", %{task: task, cookie: cookie} do
    reject(BrowserSession, :sign_in, 3)

    expect(BrowserSession, :call, fn _session, "Network.setCookie", _cookie -> {:ok, %{"success" => false}} end)

    assert {:error, {:cookie_refused, "CF_Authorization"}} =
             Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/", [cookie])

    expect(BrowserSession, :call, fn _session, "Network.setCookie", _cookie -> {:error, "Target closed"} end)

    assert {:error, "Target closed"} = Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/", [cookie])
  end

  test "says why the page could not open", %{task: task} do
    expect(BrowserSession, :sign_in, fn _session, _url, nil -> {:error, :navigation_failed} end)

    assert {:error, :navigation_failed} = Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/", [])
  end

  test "says why the browser could not start", %{cookie: cookie} do
    task = %Task{id: UXID.generate!(prefix: "tsk")}
    expect(Tools, :start_browser_session, fn ^task, "app" -> {:error, {:browser_unavailable, :enoent}} end)
    reject(BrowserSession, :call, 3)

    assert {:error, {:browser_unavailable, :enoent}} =
             Tools.open_app_tab(task, "app", "https://pr-7.preview.example.com/", [cookie])
  end
end

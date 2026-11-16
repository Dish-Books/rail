defmodule Rail.Tools.Actions.SendBrowserInput do
  @moduledoc """
  Passes what a person does to a tab on the task page, a click, a key, a scroll, Back or Reload, to the tab in Rail's
  browser.

  The event comes from the page, so only the shapes Chrome's `Input` domain takes are let through, each field
  checked, and anything else is dropped.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @mouse_types ["mousePressed", "mouseReleased", "mouseMoved"]
  @buttons ["none", "left", "middle", "right"]
  @key_types ["keyDown", "keyUp", "rawKeyDown", "char"]
  @viewport {1920, 1080}

  @doc """
  Sends `event` to the browser `name` on `task`. Returns `:ok`, `{:error, :no_browser}`, or
  `{:error, :invalid_input}` for an event of no shape it knows.
  """
  def send_browser_input(%Task{} = task, name, event) when is_binary(name) and is_map(event) do
    with {:ok, method, params} <- cdp(event),
         pid when is_pid(pid) <- Tools.get_browser_session(task, name) || {:error, :no_browser} do
      BrowserSession.cast(pid, method, params)
    end
  end

  defp cdp(%{"kind" => "mouse", "type" => type, "x" => x, "y" => y} = event) when type in @mouse_types do
    with {:ok, x, y} <- point(x, y) do
      button = if event["button"] in @buttons, do: event["button"], else: "none"

      {:ok, "Input.dispatchMouseEvent",
       %{
         type: type,
         x: x,
         y: y,
         button: button,
         buttons: if(type == "mouseMoved" and button == "none", do: 0, else: buttons(button)),
         clickCount: count(event["click_count"]),
         modifiers: modifiers(event["modifiers"])
       }}
    end
  end

  defp cdp(%{"kind" => "wheel", "x" => x, "y" => y, "dx" => dx, "dy" => dy}) when is_number(dx) and is_number(dy) do
    with {:ok, x, y} <- point(x, y) do
      {:ok, "Input.dispatchMouseEvent", %{type: "mouseWheel", x: x, y: y, deltaX: dx, deltaY: dy}}
    end
  end

  defp cdp(%{"kind" => "key", "type" => type, "key" => "" <> key, "code" => "" <> code} = event)
       when type in @key_types do
    params =
      %{type: type, key: key, code: code, modifiers: modifiers(event["modifiers"])}
      |> put_number(:windowsVirtualKeyCode, event["key_code"])
      |> put_text(event["text"])

    {:ok, "Input.dispatchKeyEvent", params}
  end

  defp cdp(%{"kind" => "text", "text" => "" <> text}) when byte_size(text) in 1..10_000,
    do: {:ok, "Input.insertText", %{text: text}}

  defp cdp(%{"kind" => "navigate", "to" => "reload"}), do: {:ok, "Page.reload", %{}}
  defp cdp(%{"kind" => "navigate", "to" => "back"}), do: {:ok, "Runtime.evaluate", %{expression: "history.back()"}}

  defp cdp(_other), do: {:error, :invalid_input}

  defp point(x, y) when is_number(x) and is_number(y) do
    {width, height} = @viewport
    if x >= 0 and x <= width and y >= 0 and y <= height, do: {:ok, x, y}, else: {:error, :invalid_input}
  end

  defp point(_x, _y), do: {:error, :invalid_input}

  defp buttons("left"), do: 1
  defp buttons("right"), do: 2
  defp buttons("middle"), do: 4
  defp buttons("none"), do: 0

  defp count(count) when count in 1..3, do: count
  defp count(_other), do: 1

  # Alt 1, Ctrl 2, Meta 4, Shift 8, as Chrome adds them up.
  defp modifiers(bits) when is_integer(bits) and bits in 0..15, do: bits
  defp modifiers(_other), do: 0

  defp put_number(params, key, value) when is_integer(value) and value in 0..255, do: Map.put(params, key, value)
  defp put_number(params, _key, _value), do: params

  # A key that types puts its character in; Enter is said as a carriage return, as a keyboard sends it.
  defp put_text(params, "" <> text) when byte_size(text) in 1..8,
    do: Map.merge(params, %{text: text, unmodifiedText: text})

  defp put_text(params, _none), do: params
end

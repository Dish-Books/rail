defmodule Rail.Tools.Actions.SendBrowserInput do
  @moduledoc """
  A teammate's click, key or scroll on one of a task's browsers, sent to its tab as DevTools input events.
  Refused while any run on the task is in flight, since that run is driving the browser. A session process
  gone since a restart is attached to its tab again; a browser with no tab is never opened.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @in_flight [:starting, :running, :waiting_for_resources, :waiting_for_usage]
  @width 1920
  @height 1080

  # Chrome acts on a key it has no text for only by its Windows key code.
  @key_codes %{
    "Backspace" => 8,
    "Tab" => 9,
    "Enter" => 13,
    "Escape" => 27,
    "PageUp" => 33,
    "PageDown" => 34,
    "End" => 35,
    "Home" => 36,
    "ArrowLeft" => 37,
    "ArrowUp" => 38,
    "ArrowRight" => 39,
    "ArrowDown" => 40,
    "Delete" => 46
  }

  @doc """
  Sends `event` to the browser `name` on `task`: `%{"type" => "click", "x", "y"}` in page pixels,
  `%{"type" => "key", "key", "code", "modifiers"}` as the browser's KeyboardEvent names them, or
  `%{"type" => "wheel", "x", "y", "dx", "dy"}`. Returns `:ok`, or `{:error, reason}`.
  """
  def send_browser_input(%Scope{} = scope, %Task{} = task, name, event) when is_binary(name) do
    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- idle(task),
         {:ok, calls} <- calls(event),
         {:ok, session} <- session(task, name) do
      Enum.reduce_while(calls, :ok, fn {method, params}, :ok ->
        case BrowserSession.call(session, method, params) do
          {:ok, _answer} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp idle(%Task{id: task_id}) do
    if Repo.exists?(from r in Run, where: r.task_id == ^task_id and r.status in @in_flight),
      do: {:error, :run_in_flight},
      else: :ok
  end

  defp session(%Task{} = task, name) do
    case Tools.get_browser_session(task, name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> Tools.start_browser_session(task, name, existing: true)
    end
  end

  defp calls(%{"type" => "click", "x" => x, "y" => y}) when is_number(x) and is_number(y) do
    point = %{x: clamp(x, @width), y: clamp(y, @height), button: "left", clickCount: 1}

    {:ok,
     [
       {"Input.dispatchMouseEvent", Map.put(point, :type, "mousePressed")},
       {"Input.dispatchMouseEvent", Map.put(point, :type, "mouseReleased")}
     ]}
  end

  defp calls(%{"type" => "wheel", "x" => x, "y" => y, "dx" => dx, "dy" => dy})
       when is_number(x) and is_number(y) and is_number(dx) and is_number(dy) do
    {:ok,
     [
       {"Input.dispatchMouseEvent",
        %{type: "mouseWheel", x: clamp(x, @width), y: clamp(y, @height), deltaX: dx, deltaY: dy}}
     ]}
  end

  defp calls(%{"type" => "key", "key" => key, "code" => code} = event) when is_binary(key) and is_binary(code) do
    modifiers = if is_integer(event["modifiers"]), do: event["modifiers"], else: 0
    key_event = %{key: key, code: code, modifiers: modifiers, windowsVirtualKeyCode: Map.get(@key_codes, key, 0)}

    down =
      case text(key, modifiers) do
        text when is_binary(text) -> Map.merge(key_event, %{type: "keyDown", text: text})
        nil -> Map.put(key_event, :type, "rawKeyDown")
      end

    {:ok, [{"Input.dispatchKeyEvent", down}, {"Input.dispatchKeyEvent", Map.put(key_event, :type, "keyUp")}]}
  end

  defp calls(_unknown), do: {:error, :unknown_event}

  # A character typed with Ctrl or Meta held is a shortcut, not text.
  defp text("Enter", _modifiers), do: "\r"

  defp text(key, modifiers) do
    if String.length(key) == 1 and Bitwise.band(modifiers, 6) == 0, do: key
  end

  defp clamp(value, limit), do: value |> max(0) |> min(limit)
end

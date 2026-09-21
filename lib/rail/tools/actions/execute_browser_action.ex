defmodule Rail.Tools.Actions.ExecuteBrowserAction do
  @moduledoc """
  Does one thing to the page, or refuses to.

  Between reading a page and acting on it the page can move, and the gap is real:
  a decision takes a network round trip. So the element is resolved again
  immediately before input - still there, still visible, still enabled, still
  where it was, and still the thing that would receive a click at that point. Any
  of those failing means the page is not the one the decision was made about, and
  nothing is done.

  Input is dispatched as real mouse and keyboard events at the element's own
  centre rather than by calling `click()` on it, because a framework listening for
  a click is listening for the event a person would produce. A click that only
  fires a handler is a check that proves less than it appears to.

  Two controls cannot take input that way and are set while the element is still
  held: a dropdown, whose list the operating system draws, and a date or time
  input, whose segments no keystroke reaches. Both dispatch the `input` and
  `change` a person's edit would have raised. It is worth knowing what that does
  not prove - a date set this way never exercised the picker's own keyboard
  handling - but the alternative is a field QA cannot fill at all.

  Afterwards it waits for the page to be worth reading again: two frames, or up
  to 200ms for the suggestions a combobox brings up, since those are the point of
  having typed.
  """

  alias Rail.Tools.BrowserSession

  @resolve [__DIR__, "..", "..", "..", "..", "priv", "browser", "resolve.js"] |> Path.join() |> Path.expand()
  @settle [__DIR__, "..", "..", "..", "..", "priv", "browser", "settle.js"] |> Path.join() |> Path.expand()

  @external_resource @resolve
  @external_resource @settle

  @resolve_js File.read!(@resolve)
  @settle_js File.read!(@settle)

  @scroll_amount 560

  @doc """
  Carries out `action` in `session`.

  `text` is what to type and is required for a `fill`: nothing is generated here,
  so the only thing that can reach a field is what the caller wrote. A date or
  time field takes the value the HTML gives it - `yyyy-mm-dd` and friends,
  whatever the page displays - and anything else comes back as
  `{:error, {:value_rejected, text}}`.

  Returns `{:ok, executed}` naming what was done, or `{:error, {:refused, why}}`
  when the element the decision named is not one that can be acted on now. `why`
  says which - gone, disabled, hidden, off screen, covered and by what - because
  they are different answers: one is worth reading the page again, and one is
  what the check was asking about.
  """
  def execute_browser_action(session, %{"kind" => "scroll"} = action, _text) do
    delta = Map.get(action, "delta", @scroll_amount)

    with {:ok, _scrolled} <-
           BrowserSession.call(session, "Input.dispatchMouseEvent", %{
             type: "mouseWheel",
             x: 400,
             y: 400,
             deltaX: 0,
             deltaY: delta
           }) do
      {:ok, action["id"]}
    end
  end

  # A form abandoned by following a link is only recoverable by going back, and
  # the history is Chrome's rather than the page's: `history.back()` inside a page
  # that has replaced its own entries goes somewhere else.
  def execute_browser_action(session, %{"kind" => "back"} = action, _text) do
    with {:ok, %{"currentIndex" => index, "entries" => entries}} when index > 0 <-
           BrowserSession.call(session, "Page.getNavigationHistory", %{}),
         %{"id" => entry} <- Enum.at(entries, index - 1),
         {:ok, _went} <- BrowserSession.call(session, "Page.navigateToHistoryEntry", %{entryId: entry}) do
      {:ok, action["id"]}
    else
      {:ok, _no_history} -> {:error, {:refused, "nowhere to go back to", nil}}
      nil -> {:error, {:refused, "nowhere to go back to", nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute_browser_action(_session, %{"kind" => "wait"} = action, _text) do
    Process.sleep(100)

    {:ok, action["id"]}
  end

  def execute_browser_action(_session, %{"kind" => "fill"}, text) when not is_binary(text) do
    {:error, :no_text_to_type}
  end

  def execute_browser_action(session, %{"node" => node} = action, text) when is_integer(node) do
    with {:ok, point} <- resolve(session, action, text),
         :ok <- input(session, action, point, text),
         :ok <- settle(session, action) do
      {:ok, action["id"]}
    end
  end

  def execute_browser_action(_session, _action, _text), do: {:error, :not_an_observed_element}

  # The value goes in with the action, because a control the browser sets rather
  # than types is set here, while the element is still resolved.
  defp resolve(session, action, text) do
    expression = String.replace(@resolve_js, "ACTION", Jason.encode!(Map.put(action, "text", text)))

    case BrowserSession.call(session, "Runtime.evaluate", %{expression: expression, returnByValue: true}) do
      {:ok, %{"result" => %{"value" => %{"x" => x, "y" => y}}}} -> {:ok, {x, y}}
      {:ok, %{"result" => %{"value" => %{"rejected" => true}}}} -> {:error, {:value_rejected, text}}
      {:ok, %{"result" => %{"value" => %{"refused" => why} = refusal}}} -> {:error, {:refused, why, refusal["by"]}}
      {:ok, _no_answer} -> {:error, {:refused, "gone", nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A dropdown and a date are both set by the resolve step, which has to do it
  # while it still holds the element. Clicking either afterwards would only open
  # a menu the operating system draws. Everything else is clicked where it sits.
  defp input(_session, %{"kind" => "select"}, _point, _text), do: :ok
  defp input(_session, %{"picker" => true}, _point, _text), do: :ok

  defp input(session, action, {x, y}, text) do
    with :ok <- click(session, x, y) do
      type(session, action, text)
    end
  end

  defp click(session, x, y) do
    Enum.reduce_while(["mousePressed", "mouseReleased"], :ok, fn type, :ok ->
      params = %{type: type, x: x, y: y, button: "left", clickCount: 1}

      case BrowserSession.call(session, "Input.dispatchMouseEvent", params) do
        {:ok, _dispatched} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Replacing rather than appending: a field with something already in it is the
  # ordinary case, and a check that meant to enter 12 must not end up with 3412.
  defp type(session, %{"kind" => "fill"}, text) do
    with {:ok, _selected} <- select_all(session),
         {:ok, _typed} <- BrowserSession.call(session, "Input.insertText", %{text: text}) do
      :ok
    end
  end

  defp type(_session, _action, _text), do: :ok

  defp select_all(session) do
    BrowserSession.call(session, "Input.dispatchKeyEvent", %{
      type: "keyDown",
      key: "a",
      code: "KeyA",
      modifiers: select_all_modifier(),
      commands: ["selectAll"]
    })
  end

  # Command on a Mac, Control everywhere else: the editing command a browser
  # honours is the one the platform's own keyboard would send. Only one of these
  # can run on any one machine, so the other is never covered anywhere.
  # coveralls-ignore-start (the branch for the platform this is not running on)
  defp select_all_modifier do
    case :os.type() do
      {:unix, :darwin} -> 4
      _other -> 2
    end
  end

  # coveralls-ignore-stop

  defp settle(session, action) do
    expression = String.replace(@settle_js, "ACTION", Jason.encode!(action))

    case BrowserSession.call(session, "Runtime.evaluate", %{
           expression: expression,
           awaitPromise: true,
           returnByValue: true
         }) do
      {:ok, _settled} -> :ok
      {:error, _navigated_away} -> :ok
    end
  end
end

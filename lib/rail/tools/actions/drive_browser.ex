defmodule Rail.Tools.Actions.DriveBrowser do
  @moduledoc """
  Carries out one instruction on a page, however many actions that takes.

  "Click Save" is one action. "Fill in the amount and save" is several, and the
  caller should not have to know which in advance - so this loops: read the page,
  decide, act, read again, until the page shows the instruction has been carried
  out or nothing offered can carry it out.

  It stops early for one other reason. A `TYPE_TEXT` decision needs a value, and
  values come from the caller rather than from a model, so reaching a field the
  caller supplied no text for returns what was done so far and asks for it. One
  extra turn, only when a form had a field the caller did not anticipate.

  What comes back is a receipt rather than a page: where it ended up, what was
  actually executed, and how it finished. The page itself is only read when
  somebody asks for it, because that is the part that costs.
  """

  import Rail.Tools.Utils.ActionSpace

  alias Rail.Tools

  @max_actions 12

  @doc """
  Carries out `intent` in `session` and returns what it did.

  `opts` takes `:text` for a value to type, and `:on_action` - a function called
  with each executed step, which is how a log and a watching panel see a pass as
  it happens rather than when it ends.
  """
  def drive_browser(session, intent, opts \\ []) do
    with {:ok, page} <- Tools.observe_browser(session) do
      step(session, intent, page, [], opts)
    end
  end

  defp step(_session, _intent, page, history, _opts) when length(history) >= @max_actions do
    {:ok, receipt(page, history, :too_many_actions)}
  end

  defp step(session, intent, page, history, opts) do
    case Tools.decide_browser_action(page, intent, Enum.map(history, & &1.action), opts) do
      {:ok, %{operation: "DONE"}} -> {:ok, receipt(page, history, :done)}
      {:ok, %{operation: "BLOCKED"}} -> {:ok, receipt(page, history, :blocked)}
      {:ok, decision} -> act(session, intent, page, history, decision, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp act(session, intent, page, history, %{operation: "TYPE_TEXT"} = decision, opts) do
    case Keyword.get(opts, :text) do
      text when is_binary(text) -> perform(session, intent, page, history, decision, text, opts)
      nil -> {:ok, receipt(page, history, {:needs_text, decision.action["label"]})}
    end
  end

  defp act(session, intent, page, history, decision, opts) do
    perform(session, intent, page, history, decision, nil, opts)
  end

  defp perform(session, intent, page, history, decision, text, opts) do
    case Tools.execute_browser_action(session, decision.action, text) do
      {:ok, _executed} ->
        executed = executed(decision, text)
        announce(executed, opts)
        advance(session, intent, page, [executed | history], opts)

      # The page moved between reading it and acting on it, and nothing was done.
      # Reading it again and deciding afresh is the whole of the recovery.
      {:error, :stale} ->
        restart(session, intent, history, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance(session, intent, page, history, opts) do
    case Tools.observe_browser(session) do
      {:ok, fresh} -> step(session, intent, fresh, history, opts)
      {:error, reason} -> {:ok, Map.put(receipt(page, history, :done), :error, reason)}
    end
  end

  defp restart(session, intent, history, opts) do
    with {:ok, fresh} <- Tools.observe_browser(session) do
      step(session, intent, fresh, history, opts)
    end
  end

  defp executed(decision, text) do
    %{
      operation: decision.operation,
      action: decision.action["label"],
      target: decision.target,
      text: text,
      confidence: decision.confidence
    }
  end

  defp announce(executed, opts) do
    case Keyword.get(opts, :on_action) do
      announce when is_function(announce, 1) -> announce.(executed)
      nil -> :ok
    end
  end

  # What the caller gets back: enough to know the instruction landed, and not so
  # much that reading the page is something they pay for on every step.
  defp receipt(page, history, outcome) do
    {elements, _targets, _controls} = action_space(Map.get(page, "actions", []))

    %{
      outcome: outcome,
      url: page["url"],
      title: page["title"],
      executed: history |> Enum.reverse() |> Enum.map(&Map.take(&1, [:operation, :action, :text])),
      elements: length(elements)
    }
  end
end

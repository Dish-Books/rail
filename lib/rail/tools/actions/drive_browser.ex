defmodule Rail.Tools.Actions.DriveBrowser do
  @moduledoc """
  Drives a page to an outcome, however many actions that takes.

  "Click Save" is one action. "A bill for Sysco dated 12 Aug for $2,500 is
  entered and saved" is a dozen, and the caller should not have to know which in
  advance - so this loops: read the page, decide, act, read again, until the page
  shows the outcome has been reached or nothing offered can reach it. An outcome
  is what this is for: a caller asking one keystroke at a time pays the whole
  loop for each of them and hands it no idea what the keystrokes are for, which
  is how the same step gets chosen twice.

  It stops early for one other reason. A `TYPE_TEXT` decision needs a value, and
  values come from the caller rather than from a model - `:values` keyed by the
  field's label, or `:text` for an outcome that types into one field - so reaching
  a field with nothing supplied returns what was done so far and asks for it. One
  extra turn, only when a form had a field the caller did not anticipate.

  What comes back is a receipt rather than a page: where it ended up, what was
  actually executed, and how it finished. The page itself is only read when
  somebody asks for it, because that is the part that costs.
  """

  import Rail.Tools.Utils.ActionSpace

  alias Rail.Tools

  @max_steps 30

  @doc """
  Carries out `intent` in `session` and returns what it did.

  `opts` takes `:values` - what to type, keyed by the field's label - or `:text`
  for a single value, and `:on_action`, a function called with each executed
  step, which is how a log and a watching panel see a pass as it happens rather
  than when it ends.
  """
  def drive_browser(session, intent, opts \\ []) do
    pass = %{intent: intent, opts: opts}

    with {:ok, page} <- Tools.observe_browser(session) do
      step(session, pass, page, [], %{steps: 0, still: 0, refused: nil})
    end
  end

  # Twice over a page that did not move. Either the element being acted on is not
  # the one the instruction is about, or it is and the page does not care - and a
  # third go would type the same thing into the same wrong field, or ask the same
  # refused control again. The caller is told which, because only the caller can
  # do anything about either.
  defp step(_session, _pass, page, history, %{still: 2, refused: nil}) do
    {:ok, receipt(page, history, :not_moving)}
  end

  defp step(_session, _pass, page, history, %{still: 2, refused: refused}) do
    {:ok, receipt(page, history, {:refused, refused})}
  end

  # The budget is decisions rather than actions, so a page that keeps moving out
  # from under them runs out too. A decision the page then refuses is the one way
  # this loop could otherwise never end: nothing is executed, so nothing
  # accumulates, and the same decision comes back to be refused again.
  defp step(_session, _pass, page, history, %{steps: steps}) when steps >= @max_steps do
    {:ok, receipt(page, history, :too_many_actions)}
  end

  defp step(session, pass, page, history, budget) do
    case Tools.decide_browser_action(page, pass.intent, Enum.map(history, & &1.action), pass.opts) do
      {:ok, %{operation: "DONE"}} -> {:ok, receipt(page, history, :done)}
      {:ok, %{operation: "BLOCKED"}} -> {:ok, receipt(page, history, :blocked)}
      {:ok, decision} -> act(session, pass, page, history, %{budget | steps: budget.steps + 1}, decision)
      {:error, reason} -> {:error, reason}
    end
  end

  defp act(session, pass, page, history, budget, %{operation: "TYPE_TEXT"} = decision) do
    case supplied(pass.opts, decision.action["label"]) do
      text when is_binary(text) -> perform(session, pass, page, history, budget, decision, text)
      nil -> {:ok, receipt(page, history, {:needs_text, decision.action["label"]})}
    end
  end

  defp act(session, pass, page, history, budget, decision) do
    perform(session, pass, page, history, budget, decision, nil)
  end

  # The value for the field the decision landed on. A label is matched as the
  # page writes it, then without case, then as part of it - because "Number" is
  # what the caller knows and "Number · row 2" is what the grid calls it. A
  # caller with one value and one field says so with `:text` and names nothing.
  defp supplied(opts, label) do
    values = opts[:values] || %{}

    cond do
      values == %{} -> opts[:text]
      is_binary(values[label]) -> values[label]
      true -> loosely(values, label) || opts[:text]
    end
  end

  defp loosely(values, label) do
    wanted = String.downcase(label || "")

    Enum.find_value(values, fn {field, value} ->
      field = String.downcase(field)

      is_binary(value) and (String.contains?(wanted, field) or String.contains?(field, wanted)) and value
    end)
  end

  defp perform(session, pass, page, history, budget, decision, text) do
    case Tools.execute_browser_action(session, decision.action, text) do
      {:ok, _executed} ->
        executed = executed(decision, text)
        announce(executed, pass.opts)
        advance(session, pass, page, [executed | history], %{budget | refused: nil})

      # The page would not take it. Reading it again and deciding afresh is the
      # whole of the recovery, and the reason is said out loud: a control that is
      # disabled or covered is what a person watching a pass that has stopped
      # moving needs to see, and often the answer to the check as well.
      {:error, {:refused, why, by}} ->
        refused = %{label: decision.action["label"], why: why, by: by}
        announce(%{operation: "REFUSED", action: refusal_line(refused), text: nil}, pass.opts)
        restart(session, pass, page, history, %{budget | refused: refused})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refusal_line(%{label: label, why: why, by: nil}), do: "#{label} - #{why}"
  defp refusal_line(%{label: label, why: why, by: by}), do: "#{label} - #{why} by #{by}"

  defp advance(session, pass, page, history, budget) do
    case Tools.observe_browser(session) do
      {:ok, fresh} -> step(session, pass, fresh, history, moved(page, fresh, budget))
      {:error, reason} -> {:ok, Map.put(receipt(page, history, :done), :error, reason)}
    end
  end

  # A refusal is only worth a second go if the page is different when it is read
  # again: the same page refusing the same control twice is an answer, not a race.
  defp restart(session, pass, page, history, budget) do
    with {:ok, fresh} <- Tools.observe_browser(session) do
      step(session, pass, fresh, history, moved(page, fresh, budget))
    end
  end

  # The snapshot's marker is what the page means rather than how it is drawn, so
  # an animation is not movement and a value that changed is.
  defp moved(page, fresh, budget) do
    if fresh["marker"] == page["marker"],
      do: %{budget | still: budget.still + 1},
      else: %{budget | still: 0}
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

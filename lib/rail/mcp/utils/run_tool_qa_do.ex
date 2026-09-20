defmodule Rail.Mcp.Utils.RunToolQaDo do
  @moduledoc """
  Carries out one instruction on the current page and says what was executed.

  What comes back is a receipt rather than a page: the steps Rail actually took,
  where that left the browser, and how it finished. Reading the page is what
  costs, so it is asked for separately by whoever wants it.

  Each way an instruction can end reads as itself. An instruction that reached a
  field with no value supplied comes back asking for the value rather than
  inventing one; one nothing on the page can carry out says so rather than
  looking like it worked.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Carries out `arguments["intent"]` in `task`'s browser, typing
  `arguments["values"]`, or `arguments["text"]` for an outcome that types once.
  """
  def run_tool_qa_do(%Task{} = task, %{"intent" => intent} = arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts),
         driving = Keyword.merge(opts, text: arguments["text"], values: arguments["values"]),
         {:ok, receipt} <- Tools.drive_browser(session, intent, driving) do
      {:ok, receipt_text(receipt)}
    end
  end

  defp receipt_text(%{outcome: {:needs_text, field}} = receipt) do
    """
    #{done(receipt)}
    Stopped at "#{field}", which needs a value. Say the instruction again with the text to enter.
    """
  end

  defp receipt_text(%{outcome: :blocked} = receipt) do
    """
    #{done(receipt)}
    Nothing on this page can carry that out. #{receipt.url} - #{receipt.title}
    """
  end

  defp receipt_text(%{outcome: {:refused, refused}} = receipt) do
    """
    #{done(receipt)}
    Stopped: "#{refused.label}" #{refusal(refused)}, twice over a page that did not change.
    That is the page's answer rather than something to word differently. #{receipt.url} - #{receipt.title}
    """
  end

  defp receipt_text(%{outcome: :not_moving} = receipt) do
    """
    #{done(receipt)}
    Stopped: the last steps left the page exactly as they found it, so they were not doing what you asked.
    Read the page and name the element another way. #{receipt.url} - #{receipt.title}
    """
  end

  defp receipt_text(%{outcome: :too_many_actions} = receipt) do
    """
    #{done(receipt)}
    Stopped after too many actions without finishing. #{receipt.url} - #{receipt.title}
    """
  end

  # Nothing done and nothing left to do means the page already read as carrying
  # the instruction out. Saying which of the two it was is what stops a caller
  # asking the same thing again in different words.
  defp receipt_text(%{outcome: :done, executed: []} = receipt) do
    """
    Did nothing: the page already reads as having that carried out.
    Read the page before asking again - the same instruction reworded lands the same way.
    #{receipt.url} - #{receipt.title}
    """
  end

  defp receipt_text(receipt) do
    """
    #{done(receipt)}
    Now at #{receipt.url} - #{receipt.title}
    """
  end

  defp done(%{executed: []}), do: "Did nothing."

  defp done(%{executed: executed}) do
    Enum.map_join(executed, "\n", fn step ->
      "#{step.operation} #{inspect(step.action)}#{typed(step)}"
    end)
  end

  defp refusal(%{why: why, by: nil}), do: "is #{why}"
  defp refusal(%{why: why, by: by}), do: "is #{why} by #{by}"

  defp typed(%{text: text}) when is_binary(text), do: " ← #{inspect(text)}"
  defp typed(_step), do: ""
end

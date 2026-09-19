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
  `arguments["text"]` where a step needs a value.
  """
  def run_tool_qa_do(%Task{} = task, %{"intent" => intent} = arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts),
         {:ok, receipt} <- Tools.drive_browser(session, intent, Keyword.put(opts, :text, arguments["text"])) do
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

  defp receipt_text(%{outcome: :too_many_actions} = receipt) do
    """
    #{done(receipt)}
    Stopped after too many actions without finishing. #{receipt.url} - #{receipt.title}
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

  defp typed(%{text: text}) when is_binary(text), do: " ← #{inspect(text)}"
  defp typed(_step), do: ""
end

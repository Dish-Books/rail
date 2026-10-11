defmodule Rail.Mcp.Utils.RunToolQaShot do
  @moduledoc """
  Photographs the page into the task's QA folder and returns the path, never the picture, which the explorer
  reads to check it shows what it was taken for before the lead cites it.
  """

  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  # Rail clears its width after the picture, which also ends a width an explorer's script set.
  @unsized " The tab is back at its own width now, so a script holding a resize has to set it again."

  @doc """
  Captures what the browser `arguments["browser"]` names on `task` is looking at as `arguments["name"]`,
  laid out `arguments["width"]` wide when given, and says where it was saved.
  """
  def run_tool_qa_shot(%Task{} = task, %{"name" => name} = arguments, opts) when is_binary(name) do
    with {:ok, width} <- width(arguments["width"]),
         {:ok, _browser, session} <- named_browser(task, arguments, opts),
         {:ok, file} <- Tools.capture_browser_evidence(session, task, name, width: width) do
      {:ok,
       "Saved as #{file}. Read it now and check it shows what its name says, meaning the screen, the state and the width. " <>
         "Give the path to the lead only once it does, and take it again if it does not." <>
         if(width, do: @unsized, else: "")}
    else
      {:error, :flat_screenshot} ->
        {:refused,
         "Refused, nothing saved. The picture came back all one color, so the page had not painted or the tab is " <>
           "still blank. Wait for what the check is about to show, then take it again. If the page really renders " <>
           "blank, report that with its URL and the steps that reach it, as text."}

      {:refused, said} ->
        {:refused, said}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_tool_qa_shot(%Task{}, _arguments, _opts) do
    {:refused, "qa_shot needs a `name` saying what the picture shows. Nothing was saved."}
  end

  defp width(width) when is_integer(width) and width in 320..1920, do: {:ok, width}
  defp width(nil), do: {:ok, nil}

  defp width(_width),
    do: {:refused, "`width` is the width to lay the page out at, a whole number from 320 to 1920. Nothing was saved."}
end

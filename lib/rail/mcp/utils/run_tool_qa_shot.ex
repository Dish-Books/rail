defmodule Rail.Mcp.Utils.RunToolQaShot do
  @moduledoc """
  Photographs the page into the task's QA folder and returns the path, never the picture, so reading it
  into the context is the agent's own choice.
  """

  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Captures what the browser `arguments["browser"]` names on `task` is looking at as `arguments["name"]`,
  and says where it was saved.
  """
  def run_tool_qa_shot(%Task{} = task, %{"name" => name} = arguments, opts) when is_binary(name) do
    with {:ok, _browser, session} <- named_browser(task, arguments, opts),
         {:ok, file} <- Tools.capture_browser_evidence(session, task, name) do
      {:ok,
       "Saved as #{file}. Give that path to the lead for the finding's evidence. Reading it is how you check " <>
         "how something looks, and it stays in your context once you do, so read it only when a check turns on that."}
    end
  end

  def run_tool_qa_shot(%Task{}, _arguments, _opts) do
    {:refused, "qa_shot needs a `name` saying what the picture shows. Nothing was saved."}
  end
end

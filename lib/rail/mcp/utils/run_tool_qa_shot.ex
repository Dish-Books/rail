defmodule Rail.Mcp.Utils.RunToolQaShot do
  @moduledoc """
  Photographs the page and files it against the task.

  The caller says what the picture is of and which check it is for; Rail names the
  file and hands back the name to cite in a finding. So no path ever arrives from
  a model, and there is nothing to validate on the way in or the way out.

  The check is what puts the picture somewhere a reader will find it: the panel
  shows every row of the checklist with the pictures taken for it, so a shot
  filed against no check is one only a finding can reach.

  What comes back is the name, never the picture. Whether the picture costs
  anything is then the agent's own decision: reading it puts it in the context
  for the rest of the pass, and a finding that only cites the file costs nothing
  at all.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Captures what `task`'s browser is looking at as `arguments["name"]`, against the
  check `arguments["check"]`, and says where it was filed.
  """
  def run_tool_qa_shot(%Task{} = task, %{"name" => name} = arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts),
         {:ok, file} <- Tools.capture_browser_evidence(session, task, name, arguments["check"]) do
      {:ok,
       "Filed as #{file}. Cite that name in the finding's evidence. Reading it is how you check how " <>
         "something looks, and it stays in your context once you do, so read it only when a check turns on that."}
    end
  end
end

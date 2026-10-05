defmodule Rail.Mcp.Utils.RunToolSaveTicket do
  @moduledoc """
  Saves the product agent's ticket, from its first draft to its last.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @fields ["title", "description", "priority", "estimate"]

  @doc """
  Saves the ticket in `arguments` on `task` and says what was saved, or hands
  back the changeset that refused it.
  """
  def run_tool_save_ticket(%Task{} = task, arguments, _opts) do
    with {:ok, %{title: title}} <- Pipeline.save_ticket(task, Map.take(arguments, @fields)) do
      {:ok, "Ticket saved: #{title}. Save it again after every change; the human reads the last save."}
    end
  end
end

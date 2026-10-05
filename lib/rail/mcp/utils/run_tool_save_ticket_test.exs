defmodule Rail.Mcp.Utils.RunToolSaveTicketTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_ticket_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_rt_ticket", scratch_path: scratch, issue: %Issue{identifier: "RTT-1", priority: :low}}}
  end

  test "a good save is receipted by its title, taking only the fields the tool declares", %{task: task} do
    assert {:ok, "Ticket saved: One round. " <> _rest} =
             run_tool_save_ticket(task, %{"title" => "One round", "description" => "Body.", "status" => "done"}, [])

    assert %{title: "One round", priority: :low} = Pipeline.read_ticket(task)
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_ticket(task, %{"title" => "One round"}, [])
  end
end

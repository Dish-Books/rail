defmodule Rail.Pipeline.Actions.ReadTicketTest do
  use ExUnit.Case, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_ticket_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "tickets"))
    on_exit(fn -> File.rm_rf(scratch) end)

    %{scratch: scratch, task: %Task{scratch_path: scratch, issue: %Issue{identifier: "RDT-1"}}}
  end

  test "returns the ticket the product run saved, parsed", %{scratch: scratch, task: task} do
    File.write!(Path.join([scratch, "tickets", "RDT-1.md"]), "---\ntitle: A ticket\npriority: high\n---\nThe body.")

    assert %{title: "A ticket", description: "The body.", priority: :high} = Pipeline.read_ticket(task)
  end

  test "the ticket carries when it was last saved", %{scratch: scratch, task: task} do
    File.write!(Path.join([scratch, "tickets", "RDT-1.md"]), "---\ntitle: A ticket\n---\nThe body.")
    File.touch!(Path.join([scratch, "tickets", "RDT-1.md"]), 1_790_000_000)

    assert %{saved_at: ~U[2026-09-21 14:13:20Z]} = Pipeline.read_ticket(task)
  end

  test "a blank ticket is no ticket", %{scratch: scratch, task: task} do
    File.write!(Path.join([scratch, "tickets", "RDT-1.md"]), "  \n")

    assert Pipeline.read_ticket(task) == nil
  end

  test "no file yet is no ticket", %{task: task} do
    assert Pipeline.read_ticket(task) == nil
  end

  test "a child of a split reads its own issue, though it has no scratch ticket", %{scratch: scratch} do
    issue = %Issue{identifier: "RDT-2", title: "Part two", description: "The part.", priority: :high, estimate: 2}
    task = %Task{scratch_path: scratch, parent_task_id: "tsk_parent", inserted_at: ~U[2026-10-11 09:00:00Z], issue: issue}

    assert %{
             title: "Part two",
             description: "The part.",
             priority: :high,
             estimate: 2,
             saved_at: ~U[2026-10-11 09:00:00Z]
           } = Pipeline.read_ticket(task)
  end

  test "a task with no parent reads only its scratch ticket, not its issue", %{task: task} do
    task = %{task | issue: %Issue{identifier: "RDT-1", title: "The issue", description: "Issue body."}}

    assert Pipeline.read_ticket(task) == nil
  end
end

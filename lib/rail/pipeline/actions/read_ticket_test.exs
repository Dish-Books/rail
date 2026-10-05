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
end

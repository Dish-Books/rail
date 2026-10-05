defmodule Rail.Pipeline.Actions.SaveTicketTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_ticket_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_ticket_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SVT-1", title: "Raw ask", priority: :low, estimate: 2}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task, path: Path.join([scratch, "tickets", "SVT-1.md"])}
  end

  test "a good save is written where read_ticket reads it, and every open page hears", %{task: %{id: task_id} = task} do
    assert {:ok, %{title: "Diff comments go as one round", description: "The body.", priority: :high, estimate: 3}} =
             Pipeline.save_ticket(task, %{
               "title" => "Diff comments go as one round",
               "description" => "The body.",
               "priority" => "high",
               "estimate" => 3
             })

    assert %{title: "Diff comments go as one round", priority: :high, saved_at: %DateTime{}} = Pipeline.read_ticket(task)
    assert_received {:output_saved, ^task_id}
  end

  test "a priority or estimate left out keeps the issue's own", %{task: task} do
    assert {:ok, %{priority: :low, estimate: 2}} =
             Pipeline.save_ticket(task, %{"title" => "A title", "description" => "Body.", "priority" => nil})
  end

  test "each bad field is refused, and nothing is written", %{task: task, path: path} do
    assert {:error, changeset} =
             Pipeline.save_ticket(task, %{
               "title" => "Two\nlines",
               "description" => " ",
               "priority" => "soon",
               "estimate" => -1
             })

    assert %{
             title: ["must be one line"],
             description: ["can't be blank"],
             priority: ["is invalid"],
             estimate: ["must be zero or more"]
           } = errors_on(changeset)

    refute File.exists?(path)
    refute_received {:output_saved, _task_id}
  end

  test "a refused save leaves the earlier ticket byte for byte, and a good one replaces it", %{
    task: task,
    path: path
  } do
    {:ok, _first} = Pipeline.save_ticket(task, %{"title" => "First", "description" => "One."})
    written = File.read!(path)

    assert {:error, _refused} = Pipeline.save_ticket(task, %{"title" => "", "description" => "Two."})
    assert File.read!(path) == written

    assert {:ok, %{title: "Second", description: "Two."}} =
             Pipeline.save_ticket(task, %{"title" => "Second", "description" => "Two."})

    assert Path.wildcard(Path.join(Path.dirname(path), ".*")) == []
  end
end

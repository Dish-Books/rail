defmodule Rail.Pipeline.Actions.SendMessageTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Rail.Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_send_message_1",
              "identifier" => "SND-1",
              "title" => "Send Message Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Send Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    idle = fn ->
      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          conversation_id: "sess_send_message",
          started_at: DateTime.utc_now()
        })

      run
    end

    %{project: project, task: task, role: role, idle: idle}
  end

  test "a message to an idle run goes out now", %{idle: idle} do
    run = idle.()
    test = self()

    # The spawn is in the background; waited on, so it never outlives the test's stubs.
    stub(Tools, :start_os_process, fn spawned, _argv ->
      send(test, {:spawned, spawned.id})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :sent, %Run{id: run_id}} = Pipeline.send_message(system_scope(), run, "Please add a test")
    assert_receive {:spawned, ^run_id}
  end

  test "a message whose run is deleted while it waits on the task's lock starts nothing", %{idle: idle} do
    %Run{id: run_id, task_id: task_id} = run = idle.()
    test = self()

    stub(Rail.Git, :get_or_create_worktree, fn _project, task ->
      send(test, :worktree)
      {:ok, task.worktree_path}
    end)

    stub(Tools, :start_os_process, fn spawned, _argv ->
      send(test, :spawned)
      {:ok, %OsProcess{run: spawned}}
    end)

    with_task_lock(task_id, fn ->
      assert {:ok, :sent, %Run{}} = Pipeline.send_message(system_scope(), run, "Please add a test")
      # Long enough for a dispatch that took no lock to have made its worktree.
      refute_receive :worktree, 200
      Repo.delete_all(from(r in Run, where: r.id == ^run_id))
    end)

    refute_receive :worktree, 300
    refute_received :spawned
  end

  test "a message to a working run waits on it", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    assert {:ok, :queued, %Run{pending_chat: "Please add a test"}} =
             Pipeline.send_message(system_scope(), run, "Please add a test")
  end

  test "a second thought lands behind the first in the same turn", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(system_scope(), run, "First")
    assert {:ok, :queued, %Run{pending_chat: "First\n\nSecond"}} = Pipeline.send_message(system_scope(), run, "Second")
  end

  # Everyone on the task reads the same conversation, so each line says who sent it.
  test "the human's words go into the log as they are typed, under who sent them", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()
    %{user: %{id: user_id}} = scope = user_scope()

    {:ok, :queued, run} = Pipeline.send_message(scope, run, "One line\nAnother line")

    assert Enum.map(Pipeline.list_run_events(run), & &1.line) ==
             ["[human:#{user_id}] One line", "[human:#{user_id}] Another line"]
  end

  test "a message from nobody in particular is logged as the human's", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(system_scope(), run, "One line")

    assert ["[human] One line"] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "pictures sent with a message are kept in scratch, logged under who sent them and pointed at in the message", %{
    task: task,
    idle: idle
  } do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()
    %{user: %{id: user_id}} = scope = user_scope()
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    images = [%{name: "Screenshot.PNG", data: "PNG_BYTES"}, %{name: "photo.jpeg", data: "JPEG_BYTES"}]
    assert {:ok, :queued, %Run{} = queued} = Pipeline.send_message(scope, run, "Look at this", images: images)

    image_tag = "[human-image:#{user_id}] "
    [text, png_line, jpeg_line] = Enum.map(Pipeline.list_run_events(run), & &1.line)

    assert text == "[human:#{user_id}] Look at this"
    png = String.replace_prefix(png_line, image_tag, "")
    jpeg = String.replace_prefix(jpeg_line, image_tag, "")
    assert png =~ ~r/\A[0-9a-f-]{36}\.png\z/
    assert jpeg =~ ~r/\A[0-9a-f-]{36}\.jpeg\z/
    png_path = Path.join([task.scratch_path, "attachments", png])
    jpeg_path = Path.join([task.scratch_path, "attachments", jpeg])
    assert File.read!(png_path) == "PNG_BYTES"
    assert File.read!(jpeg_path) == "JPEG_BYTES"

    pending =
      "Look at this\n[Attached image, open it with Read: #{png_path}]\n[Attached image, open it with Read: #{jpeg_path}]"

    assert %Run{pending_chat: ^pending} = queued
  end

  test "a message can be pictures alone, but not a file that is not a picture", %{task: task, idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    assert {:ok, :queued, %Run{pending_chat: "[Attached image, open it with Read: " <> _path}} =
             Pipeline.send_message(system_scope(), run, "  ", images: [%{name: "shot.webp", data: "WEBP"}])

    assert ["[human-image] " <> _file] = Enum.map(Pipeline.list_run_events(run), & &1.line)

    assert {:error, :not_an_image} =
             Pipeline.send_message(system_scope(), run, "Notes", images: [%{name: "notes.pdf", data: "PDF"}])
  end

  test "pictures an earlier send kept go again first, and a name it never kept is refused", %{task: task, idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, :queued, first} = Pipeline.send_message(system_scope(), run, "", images: [%{name: "a.png", data: "A"}])
    {"", [kept]} = Pipeline.split_message_images(first.pending_chat)
    {:ok, _stopped} = first |> Run.changeset(%{pending_chat: nil}) |> Repo.update()

    assert {:ok, :queued, %Run{pending_chat: pending}} =
             Pipeline.send_message(system_scope(), run, "Again",
               images: [%{name: "b.png", data: "B"}],
               attachments: [kept]
             )

    assert {"Again", [^kept, new]} = Pipeline.split_message_images(pending)
    assert File.read!(Path.join([task.scratch_path, "attachments", new])) == "B"

    for name <- ["../../etc/passwd", "#{Ecto.UUID.generate()}.png"] do
      assert {:error, :attachment_not_found} = Pipeline.send_message(system_scope(), run, "", attachments: [name])
    end
  end

  test "a working run that has not recorded its conversation yet still queues", %{task: task, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, :queued, %Run{pending_chat: "Anyone there?"}} =
             Pipeline.send_message(system_scope(), run, "Anyone there?")
  end

  test "a run holding no conversation cannot be messaged", %{task: task, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :chat_unavailable} = Pipeline.send_message(system_scope(), run, "Anyone there?")
  end

  test "an empty message is not a message", %{idle: idle} do
    run = idle.()

    assert {:error, :empty_message} = Pipeline.send_message(system_scope(), run, "   ")
    assert {:error, :empty_message} = Pipeline.send_message(system_scope(), run, nil)
  end

  test "a run that is gone cannot be messaged", %{idle: idle} do
    run = idle.()
    Repo.delete!(run)

    assert {:error, :not_found} = Pipeline.send_message(system_scope(), run, "Hello?")
  end

  # Review's fixes are the Review lead's to hand its engineer, so a message here would change the branch behind it.
  test "the engineer's conversation closes once the task leaves Engineer", %{task: task, idle: idle} do
    run = idle.()
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    reject(Tools, :start_os_process, 2)

    assert {:error, {:invalid_stage, :review}} = Pipeline.send_message(system_scope(), run, "One more thing")
    assert [] = Pipeline.list_run_events(run)
  end

  test "a custom stage's conversation takes messages at its stage, and closes once the task moves past it", %{
    project: project,
    task: task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :custom, custom_stage: "License check"})
    {:ok, role} = Roles.get_custom_stage_role(project.id, "License check")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_send_custom",
        started_at: DateTime.utc_now()
      })

    assert {:ok, :queued, %Run{}} = Pipeline.send_message(system_scope(), run, "Say which screens.")

    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    assert {:error, {:invalid_stage, :review}} = Pipeline.send_message(system_scope(), run, "One more thing")
  end
end

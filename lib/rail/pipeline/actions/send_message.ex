defmodule Rail.Pipeline.Actions.SendMessage do
  @moduledoc """
  Sends a message from the human, or from Rail on its behalf, to the agent holding a run's conversation.

  There is one rule: if the run is working, the message waits on
  it; if it is not, the message goes out now. Waiting is the only reason a queue
  exists, so nothing here asks what the rest of the task is doing — a message to
  an idle reviewer goes out whether or not the engineer is busy.

  Queued messages accumulate rather than replacing, so a second thought lands
  after the first one in the same turn.

  The engineer's own conversation closes once the task leaves Engineer: Review's
  fixes are the Review lead's to hand its engineer, so a message there would
  change the branch behind Review's back. A custom stage's closes once it is approved, so its file stays as approved.

  A person's message to the Review lead of a task a teammate marked ready takes the mark off, as a Send in the Review
  tray does, since changes are coming: the task leaves the review queue until someone marks it again.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.DispatchMessage
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  # What Claude Code's Read tool shows as a picture, by the name's own extension.
  @image_extensions [".png", ".jpg", ".jpeg", ".gif", ".webp"]
  # The only names a send stores pictures under, so a name handed back never reaches outside the folder.
  @attachment_name ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|gif|webp)\z/

  @doc """
  Sends `text` to `run` from the scope's user or, with `from: :past_answers`, from Rail answering out of past answers.

  `images:` takes `%{name:, data:}` pictures, kept in the task's scratch folder for the agent to read, and
  `attachments:` the names of pictures an earlier send kept there, which go first; with either, `text` may be blank. Returns `{:ok, :sent, run}` when it went out, `{:ok, :queued, run}` when the agent is still
  working and it will go out when the turn ends.
  """
  def send_message(%Scope{} = scope, %Run{} = run, text, opts \\ []) do
    images = Keyword.get(opts, :images, [])
    attachments = Keyword.get(opts, :attachments, [])

    with %Run{} = run <- Run |> Repo.get(run.id) |> Repo.preload([:task, :role]),
         :ok <- validate_open(run),
         :ok <- validate_can_chat(run),
         :ok <- validate_images(images),
         {:ok, kept} <- find_attachments(run, attachments),
         {:ok, trimmed} <- validate_message(text, images ++ attachments) do
      deliver(scope, run, trimmed, kept ++ save_images(run, images), opts[:from])
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_open(%Run{role: %Role{stage: :engineer}, task: %Task{stage: stage}}) when stage != :engineer,
    do: {:error, {:invalid_stage, stage}}

  defp validate_open(%Run{role: %Role{custom_stage: name} = role, task: %Task{} = task}) when is_binary(name) do
    if Task.works_stage?(task, role), do: :ok, else: {:error, {:invalid_stage, task.stage}}
  end

  defp validate_open(%Run{}), do: :ok

  defp validate_can_chat(%Run{} = run) do
    if Run.can_chat?(run), do: :ok, else: {:error, :chat_unavailable}
  end

  defp validate_images(images) do
    if Enum.all?(images, &(String.downcase(Path.extname(&1.name)) in @image_extensions)),
      do: :ok,
      else: {:error, :not_an_image}
  end

  defp find_attachments(%Run{task: task}, files) do
    kept =
      for file <- files,
          Regex.match?(@attachment_name, file),
          path = Path.join([task.scratch_path, "attachments", file]),
          File.regular?(path),
          do: %{file: file, path: path}

    if length(kept) == length(files), do: {:ok, kept}, else: {:error, :attachment_not_found}
  end

  defp validate_message(text, images) when is_binary(text) do
    case {String.trim(text), images} do
      {"", []} -> {:error, :empty_message}
      {trimmed, _images} -> {:ok, trimmed}
    end
  end

  defp validate_message(_other, _images), do: {:error, :empty_message}

  # Each under a fresh name, so the file a sent message points at is never another's.
  defp save_images(%Run{task: task}, images) do
    for %{name: name, data: data} <- images do
      file = "#{Ecto.UUID.generate()}#{String.downcase(Path.extname(name))}"
      path = Path.join([task.scratch_path, "attachments", file])
      :ok = write_scratch_file(path, data)
      %{file: file, path: path}
    end
  end

  defp deliver(scope, %Run{} = run, text, images, from) do
    record_transcript(scope, run, text, images, from)
    unmark_ready(run, from)

    message =
      [text | Enum.map(images, &"[Attached image, open it with Read: #{&1.path}]")] |> Enum.join("\n") |> String.trim()

    {:ok, run} = run |> Run.changeset(%{pending_chat: append(run.pending_chat, message)}) |> Repo.update()

    if Run.running?(run) do
      {:ok, :queued, run}
    else
      dispatch_message(run)
      {:ok, :sent, run}
    end
  end

  # The words go into the log as they are sent, so the conversation reads in order
  # whether the agent sees them now or at the end of its turn, and says who sent them. A picture is a line of its own.
  defp record_transcript(scope, %Run{} = run, text, images, from) do
    {tag, image_tag} =
      cond do
        from == :past_answers -> {"[answered from past answers]", "[human-image]"}
        scope.user -> {"[human:#{scope.user.id}]", "[human-image:#{scope.user.id}]"}
        true -> {"[human]", "[human-image]"}
      end

    text_lines = if text == "", do: [], else: text |> String.split("\n") |> Enum.map(&"#{tag} #{&1}")
    Pipeline.append_run_events(run.id, nil, text_lines ++ Enum.map(images, &"#{image_tag} #{&1.file}"))
  end

  # Rail answering out of past answers changes nothing the person asked for, so the mark stays.
  defp unmark_ready(%Run{role: %Role{stage: :review_lead}, task: %Task{marked_ready_at: %DateTime{}} = task}, from)
       when from != :past_answers do
    {:ok, task} = task |> Task.changeset(%{marked_ready_at: nil, marked_ready_by_id: nil}) |> Repo.update()
    broadcast_pipeline_changed(task)
  end

  defp unmark_ready(%Run{}, _from), do: :ok

  defp append(nil, text), do: text
  defp append(existing, text), do: "#{existing}\n\n#{text}"
end

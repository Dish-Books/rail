defmodule RailWeb.Live.CustomStage do
  @moduledoc """
  A custom stage's item: the markdown file its agent last saved, with when and which later stages get it, and the +
  beside each line that comments on it, as the Plan step's ticket and plan have, while the stage waits on approval.
  The comments are rows, and the conversation beside it sends them.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.BuildDocumentBlocks
  import RailWeb.Utils.CalculateDocumentComments
  import RailWeb.Utils.StageOutputRecipients

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  # Another of the reader's tabs saved, removed or sent comments on the file. Only the markers moved.
  @impl true
  def update(%{reload_comments: true}, socket), do: {:ok, assign_comments(socket)}

  # A save or a finished turn the page heard of; the file is read again.
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:draft, fn -> nil end)
      |> assign_new(:error, fn -> nil end)
      |> load()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-qa="custom_stage"
      class="h-full min-w-0 overflow-y-auto px-6 @5xl:px-12 py-5 @5xl:py-6"
    >
      <p :if={@error} id={"#{@id}-error"} class="mb-3 text-xs text-red-600 dark:text-red-500">
        {@error}
      </p>

      <div
        :if={@output == nil}
        id="custom-stage-no-output"
        data-qa="custom_stage_no_output"
        class="flex flex-col items-center text-center max-w-[16rem] mx-auto py-14"
      >
        <div class={[
          "flex items-center justify-center size-12 rounded-2xl ring-1",
          @finished &&
            "bg-amber-50 dark:bg-amber-950/40 text-amber-500 ring-amber-200 dark:ring-amber-900",
          !@finished &&
            "bg-slate-100 dark:bg-slate-800 text-slate-400 ring-slate-200 dark:ring-slate-700"
        ]}>
          <.icon name="pi-file-dashed" class="size-6" />
        </div>
        <p class="mt-3 text-sm font-semibold text-slate-900 dark:text-slate-100">
          {if @finished, do: "Finished without saving its file", else: "No file yet"}
        </p>
        <p class="mt-1 text-xs leading-relaxed text-slate-500 dark:text-slate-400">
          {if @finished,
            do:
              "The task waits here until #{@name} saves it. Message #{@name} to pick up where it left off.",
            else: "The markdown #{@name} saves shows here."}
        </p>
      </div>

      <article
        :if={@output}
        id="custom-stage-output"
        data-qa="custom_stage_output"
        class="max-w-3xl select-text"
      >
        <p id="custom-stage-saved" class="text-xs text-slate-500 dark:text-slate-400">
          Saved {Calendar.strftime(@output.saved_at, "%b %-d, %H:%M")} UTC · {@recipients}
        </p>
        <div class="mt-3">
          <.changed_comments
            id="output-changed-comments"
            comments={@comments.lifted}
            target={@myself}
          />
          <.commentable_line
            :for={line <- @lines}
            line={line}
            layout={layout(line)}
            doc={:output}
            placed={@comments.placed}
            draft={@draft}
            offered={@offered}
            target={@myself}
          />
        </div>
      </article>
    </div>
    """
  end

  # The line is read off this item's own copy of the file by its key, so only a line it shows can be commented on.
  @impl true
  def handle_event("open_document_comment", %{"doc" => "output", "key" => key}, socket) do
    socket =
      case socket.assigns.offered && Enum.find(socket.assigns.lines, &(&1.key == key)) do
        %{} = line ->
          assign(socket, :draft, %{
            doc: :output,
            key: line.key,
            kind: line.kind,
            label: line.label,
            text: line.text,
            occurrence: line.occurrence,
            body: nil
          })

        _gone_or_not_offered ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("change_plan_comment", %{"body" => body}, %{assigns: %{draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :draft, %{draft | body: body})}
  end

  def handle_event("change_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_plan_comment", _params, socket), do: {:noreply, assign(socket, :draft, nil)}

  # A blank comment is refused and the box stays open on what was typed.
  def handle_event("save_plan_comment", %{"body" => body}, %{assigns: %{draft: %{} = draft}} = socket) do
    attrs = %{
      target: :output,
      body: body,
      element_kind: draft.kind,
      element_label: draft.label,
      element_occurrence: draft.occurrence,
      element_text: draft.text
    }

    case Pipeline.create_plan_comment(socket.assigns.current_scope, socket.assigns.run, attrs) do
      {:ok, _comment} ->
        socket = socket |> assign(:draft, nil) |> assign(:error, nil) |> assign_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :draft, %{draft | body: body})}

      {:error, reason} ->
        socket = socket |> assign(:draft, nil) |> assign(:error, message_for(reason)) |> load()
        {:noreply, socket}
    end
  end

  def handle_event("save_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("remove_plan_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.all_comments, &(&1.id == id)) do
      %PlanComment{} = comment ->
        {:ok, _removed} = Pipeline.delete_plan_comment(socket.assigns.current_scope, comment)
        {:noreply, assign_comments(socket)}

      # Another tab removed or sent it already.
      nil ->
        {:noreply, assign_comments(socket)}
    end
  end

  # The file is read again on every update, so a save, an approval or a turn ending shows the moment it lands.
  defp load(socket) do
    %{task: task, run: run, name: name} = socket.assigns
    output = Enum.find(Pipeline.read_stage_outputs(task), &(&1.name == name))
    approved = run.stage_outcome == :done
    offered = output != nil and not approved and Task.works_stage?(task, run.role) and Run.can_chat?(run)

    socket
    |> assign(:output, output)
    |> assign(:lines, if(output, do: build_document_blocks(output.markdown), else: []))
    |> assign(:finished, Run.state(run) == :stopped)
    |> assign(
      :recipients,
      stage_output_recipients(task.issue, name) <> if(approved, do: "", else: " once you approve it")
    )
    |> assign(:offered, offered)
    |> assign(:draft, if(offered, do: socket.assigns.draft))
    |> assign_comments()
  end

  # Numbered in round order, so a card on a line carries the number the tray gives it.
  defp assign_comments(%{assigns: %{current_scope: scope, task: task}} = socket) do
    comments = Pipeline.list_plan_comments(scope, task)
    numbered = comments |> Enum.with_index(1) |> Enum.filter(&(elem(&1, 0).target == :output))

    socket
    |> assign(:all_comments, comments)
    |> assign(:comments, calculate_document_comments(socket.assigns.lines, numbered))
  end

  defp layout(%{kind: :code}), do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text

  defp message_for(:no_output), do: "This stage's file was approved, so it takes no more comments."
  defp message_for(_chat_unavailable), do: "This stage cannot take a comment until it can be messaged."
end

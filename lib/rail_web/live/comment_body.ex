defmodule RailWeb.Live.CommentBody do
  @moduledoc """
  The text of one of the reader's unsent comments, which its card's Edit opens in a comment box in its place. Cancel,
  Escape or a save closes the box, and a blank text keeps it open on what was typed.

  The box lives here, so typing in it redraws the comment and never the card, tray or stage around it. The page holds
  the reader's scope, so a save is sent there as `{:update_comment, comment, body, id}`, and its answer comes back as
  `saved`. Drawn by `RailWeb.Components.CommentEdit.comment_body/1`, which takes its `comment`, its `label` (what it is
  on, for the box), the text's `class` as its card draws it, and `narrow` for a box in a narrow column.
  """
  use RailWeb, :live_component

  @impl true
  def mount(socket) do
    socket = socket |> assign(:editing, false) |> assign(:body, nil)
    {:ok, socket}
  end

  # A save that took closes the box on the new text, which the page reads again as the comment's tabs are told.
  @impl true
  def update(%{saved: {:ok, comment}}, socket) do
    socket = socket |> assign(:comment, comment) |> assign(:editing, false)
    {:ok, socket}
  end

  def update(%{saved: {:error, %Ecto.Changeset{}}}, socket), do: {:ok, socket}

  # Sent or removed in another tab since, so the page drops it as it reads them again.
  def update(%{saved: {:error, _reason}}, socket), do: {:ok, assign(socket, :editing, false)}

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-qa="comment_body" data-editing={@editing}>
      <.comment_box
        :if={@editing}
        id={"#{@id}-form"}
        body_id={"#{@id}-text"}
        qa="comment_edit"
        label={@label}
        body={@body}
        submit="save"
        change="change"
        cancel="cancel"
        target={@myself}
        class="mt-1"
        narrow={@narrow}
      />
      <p :if={not @editing} phx-no-format class={@class}>{@comment.body}</p>
    </div>
    """
  end

  @impl true
  def handle_event("edit", _params, socket) do
    socket = socket |> assign(:editing, true) |> assign(:body, socket.assigns.comment.body)
    {:noreply, socket}
  end

  def handle_event("change", %{"body" => body}, socket), do: {:noreply, assign(socket, :body, body)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :editing, false)}

  def handle_event("save", %{"body" => body}, socket) do
    %{comment: comment, id: id} = socket.assigns
    send(self(), {:update_comment, comment, body, id})

    {:noreply, assign(socket, :body, body)}
  end
end

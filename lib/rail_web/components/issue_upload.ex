defmodule RailWeb.Components.IssueUpload do
  @moduledoc """
  One box's file upload: images and PDFs pasted or dropped into it go up one async task each, and the hook on the box
  is told by this form's id. `issue` is the issue the files belong to, which may not be saved yet.
  """
  use RailWeb, :live_component

  alias Rail.Issues

  @max_entries 5

  def mount(socket) do
    socket =
      socket
      |> assign(:upload_error, nil)
      |> assign(:nonce, nil)
      |> assign(:started, %{})
      |> allow_upload(:file,
        accept: [".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf"],
        max_entries: @max_entries,
        max_file_size: 10_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:issue, assigns.issue)
      |> assign(:current_scope, assigns.current_scope)
      |> assign(:class, assigns[:class])
      |> forget_refusal(assigns[:nonce])

    {:ok, socket}
  end

  # Hidden while there is nothing to say, so it adds no gap to the box's layout; the input works hidden.
  def render(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="upload"
      phx-target={@myself}
      class={[!@upload_error && "hidden", @class]}
    >
      <.live_file_input upload={@uploads.file} class="hidden" />
      <p
        :if={@upload_error}
        id={"#{@id}-error"}
        role="alert"
        class="flex items-start gap-2 text-xs text-red-700 dark:text-red-300"
      >
        <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
        <span class="min-w-0 break-words [overflow-wrap:anywhere]">{@upload_error}</span>
      </p>
    </form>
    """
  end

  # The hook ties each ref to its placeholder by name, in order, so two pasted `image.png` files stay apart.
  def handle_event("upload", _params, socket) do
    %{file: upload} = socket.assigns.uploads
    new = Enum.reject(upload.entries, &Map.has_key?(socket.assigns.started, &1.ref))
    socket = Enum.reduce(new, socket, &announce/2)

    refused =
      upload.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> {entry, refusal(upload, entry, index)} end)
      |> Enum.filter(fn {_entry, reason} -> is_binary(reason) end)

    socket =
      case refused do
        [] when new != [] -> assign(socket, :upload_error, nil)
        [] -> socket
        _some -> assign(socket, :upload_error, Enum.map_join(refused, " ", fn {_entry, reason} -> reason end))
      end

    {:noreply, Enum.reduce(refused, socket, &refuse/2)}
  end

  # The hook names the files a reconnect cut off. This process never saw them, so it says they did not go up.
  def handle_event("upload_lost", %{"names" => names}, socket) when is_list(names) do
    case Enum.filter(names, &is_binary/1) do
      [] ->
        {:noreply, socket}

      lost ->
        {:noreply,
         assign(socket, :upload_error, Enum.map_join(lost, " ", &"Couldn't upload #{&1}. Try adding it again."))}
    end
  end

  def handle_event("upload_lost", _malformed, socket), do: {:noreply, socket}

  def handle_progress(:file, %{done?: true} = entry, socket) do
    %{issue: issue, current_scope: scope} = socket.assigns
    socket = announce(entry, socket)
    data = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)
    name = entry.client_name

    socket = start_async(socket, {:upload, entry.ref}, fn -> Issues.upload_file(scope, issue, name, data) end)
    {:noreply, socket}
  end

  def handle_progress(:file, entry, socket), do: {:noreply, announce(entry, socket)}

  def handle_async({:upload, ref}, {:ok, {:ok, url}}, socket) do
    {name, socket} = take_started(socket, ref)
    # A PDF goes in as a link, by the same lowercased extension the stored type comes from.
    image = String.downcase(Path.extname(name)) != ".pdf"
    payload = %{form: socket.assigns.id, ref: ref, name: name, url: url, image: image}
    {:noreply, push_event(socket, "insert_file", payload)}
  end

  def handle_async({:upload, ref}, {:ok, {:error, :not_accepted}}, socket) do
    {name, socket} = take_started(socket, ref)
    {:noreply, fail(socket, ref, "#{name} is not a PNG, JPEG, GIF, WebP or PDF file.")}
  end

  def handle_async({:upload, ref}, _refused_or_crashed, socket) do
    {name, socket} = take_started(socket, ref)
    {:noreply, fail(socket, ref, "Couldn't upload #{name}. Try adding it again.")}
  end

  defp refusal(upload, entry, index) do
    cond do
      index >= @max_entries and :too_many_files in upload_errors(upload) ->
        "Up to #{@max_entries} files go up at a time, so #{entry.client_name} was not added."

      :too_large in upload_errors(upload, entry) ->
        "#{entry.client_name} is over 10 MB, so it was not added."

      :not_accepted in upload_errors(upload, entry) ->
        "#{entry.client_name} is not a PNG, JPEG, GIF, WebP or PDF file."

      true ->
        nil
    end
  end

  # Named once per entry, from whichever of the form's change and its progress reaches the server first.
  defp announce(entry, socket) do
    if Map.has_key?(socket.assigns.started, entry.ref) do
      socket
    else
      socket
      |> update(:started, &Map.put(&1, entry.ref, entry.client_name))
      |> push_event("upload_started", %{form: socket.assigns.id, ref: entry.ref, name: entry.client_name})
    end
  end

  defp refuse({entry, _reason}, socket) do
    socket
    |> cancel_upload(:file, entry.ref)
    |> update(:started, &Map.delete(&1, entry.ref))
    |> push_event("upload_failed", %{form: socket.assigns.id, ref: entry.ref})
  end

  defp take_started(socket, ref) do
    {name, started} = Map.pop(socket.assigns.started, ref, "the file")
    {name, assign(socket, :started, started)}
  end

  defp fail(socket, ref, reason) do
    socket
    |> assign(:upload_error, reason)
    |> push_event("upload_failed", %{form: socket.assigns.id, ref: ref})
  end

  # A box that sent its comment gets a new counter, so a refusal about its files goes with the sent text.
  defp forget_refusal(%{assigns: %{nonce: nonce}} = socket, nonce), do: socket
  defp forget_refusal(socket, nonce), do: socket |> assign(:nonce, nonce) |> assign(:upload_error, nil)
end

defmodule RailWeb.Components.DescriptionEditor do
  @moduledoc """
  A Rail-tracked issue's description, edited in place by the `IssueDescription` hook and saved as the person goes.
  Images and PDFs dropped or pasted into it go up through this component, one async task each, so the page stays live.
  """
  use RailWeb, :live_component

  alias Rail.Issues

  @max_entries 5

  def mount(socket) do
    socket =
      socket
      |> assign(:upload_error, nil)
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
      |> assign(:overlay_id, assigns.overlay_id)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <%!-- LiveView leaves the editor alone; the saved text rides on data-saved, which the hook takes when it can. --%>
      <div
        id={"issue-description-#{@issue.id}"}
        data-qa="issue-description"
        phx-hook="IssueDescription"
        phx-update="ignore"
        data-issue-id={@issue.id}
        data-saved={@issue.description || ""}
        data-notice={"#{@id}-notice"}
        data-retry={"#{@id}-retry"}
        data-upload-form={"#{@id}-upload"}
        data-overlay={@overlay_id}
        class="min-h-6 break-words"
      >
        <.markdown
          :if={@issue.description not in [nil, ""]}
          content={@issue.description}
          assets_base={~p"/issues/#{@issue.id}/assets"}
          class="text-slate-700 dark:text-slate-300"
        />
        <p :if={@issue.description in [nil, ""]} class="text-sm text-slate-400 dark:text-slate-500">
          Add description...
        </p>
      </div>

      <p
        :if={@upload_error}
        id={"#{@id}-upload-error"}
        role="alert"
        class="flex items-start gap-2 text-xs text-red-700 dark:text-red-300"
      >
        <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
        <span class="min-w-0 break-words">{@upload_error}</span>
      </p>

      <%!-- The hook shows this while Rail cannot take a save, so it is rendered hidden and never by the server. --%>
      <div
        id={"#{@id}-notice"}
        role="alert"
        class="hidden items-start gap-3 rounded-xl border border-red-300 dark:border-red-500/60 bg-red-50 dark:bg-red-950/50 px-4 py-3"
      >
        <.icon
          name="pi-warning-circle-fill"
          class="h-5 w-5 shrink-0 mt-0.5 text-red-600 dark:text-red-400"
        />
        <div class="flex-1 min-w-0 space-y-0.5">
          <p class="text-sm font-semibold text-red-800 dark:text-red-200">
            Couldn't save the description
          </p>
          <p class="text-sm text-red-700 dark:text-red-200/80">
            Your changes are kept in this browser and save as soon as Rail can take them.
          </p>
        </div>
        <button
          type="button"
          id={"#{@id}-retry"}
          class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-red-400/60 text-red-800 dark:text-red-100 hover:bg-red-100 dark:hover:bg-red-900/60 cursor-pointer focus-visible:outline-2 focus-visible:outline-red-400"
        >
          <.icon name="pi-arrow-clockwise" class="h-3.5 w-3.5" />Retry now
        </button>
      </div>

      <form id={"#{@id}-upload"} phx-change="upload" phx-target={@myself} class="hidden">
        <.live_file_input upload={@uploads.file} />
      </form>
    </div>
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

    socket = if new != [] and refused == [], do: assign(socket, :upload_error, nil), else: socket
    {:noreply, Enum.reduce(refused, socket, &refuse/2)}
  end

  def handle_event("save_description", %{"description" => description}, socket) when is_binary(description) do
    %{issue: issue, current_scope: scope} = socket.assigns

    case Issues.edit_issue(scope, issue, %{"description" => description}) do
      {:ok, _issue} -> {:reply, %{ok: true}, socket}
      {:error, _reason} -> {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("save_description", _malformed, socket), do: {:reply, %{ok: false}, socket}

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
    {:noreply, push_event(socket, "insert_file", %{ref: ref, name: name, url: url, image: image})}
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
      |> push_event("upload_started", %{ref: entry.ref, name: entry.client_name})
    end
  end

  defp refuse({entry, reason}, socket) do
    socket
    |> cancel_upload(:file, entry.ref)
    |> update(:started, &Map.delete(&1, entry.ref))
    |> fail(entry.ref, reason)
  end

  defp take_started(socket, ref) do
    {name, started} = Map.pop(socket.assigns.started, ref, "the file")
    {name, assign(socket, :started, started)}
  end

  defp fail(socket, ref, reason) do
    socket
    |> assign(:upload_error, reason)
    |> push_event("upload_failed", %{ref: ref})
  end
end

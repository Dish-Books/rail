defmodule RailWeb.Components.AppPane do
  @moduledoc """
  The task's App item: its pull request as deployed outside Rail, opened signed in, in a tab of Rail's browser that a
  person uses through its picture, or in their own browser with Open in new tab. Every push redeploys it, and the item
  says so until the deployment serves the new commit.

  With Comment on, a click picks the element under it rather than clicking it, and the comment written on it goes to
  the Review lead with the screen comments. The frames are pushed to the picture by the page, never drawn through a
  render.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Preview

  attr :preview, :any, required: true, doc: "the task's `Preview`, or nil before Rail first looked for one"
  attr :has_pr, :boolean, required: true
  attr :login_url, :string, default: nil, doc: "where the preview opens, signed in"
  attr :url, :string, default: nil, doc: "where Rail's tab is now"
  attr :commenting, :boolean, required: true
  attr :commentable, :boolean, required: true, doc: "whether the task takes comments for the Review lead"
  attr :draft, :any, required: true, doc: "`%{element:, body:}` while a comment is being written"
  attr :comments, :list, required: true, doc: "the reader's unsent comments on the app"
  attr :error, :string, default: nil
  attr :target, :any, required: true

  def app_pane(assigns) do
    assigns =
      assigns
      |> assign(:status, status(assigns.has_pr, assigns.preview))
      |> assign(:path, path(assigns.url))

    ~H"""
    <div id="app-pane" data-qa="app_pane" class="flex-1 min-w-0 min-h-0 flex flex-col overflow-y-auto">
      <div class="h-12 shrink-0 flex items-center gap-2 px-5 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">App</span>
        <span data-qa="app_status" class={["text-xs font-semibold", status_class(@status)]}>
          {status_label(@status)}
        </span>
        <span
          :if={@preview}
          data-qa="app_host"
          class="min-w-0 truncate text-xs font-mono text-slate-500 dark:text-slate-400"
        >
          {host(@preview.url)}
        </span>
        <span
          :if={@status == :live and @preview.live_sha}
          class="shrink-0 text-xs font-mono text-slate-400 dark:text-slate-500"
        >
          {String.slice(@preview.live_sha, 0, 7)}
        </span>
        <span class="ml-auto" />
        <button
          :if={@status == :live}
          type="button"
          id="app-sign-in"
          data-qa="app_sign_in"
          phx-click="app_sign_in"
          phx-target={@target}
          class={secondary_button()}
        >
          <.icon name="pi-sign-in" class="size-[15px]" /> Sign in again
        </button>
        <a
          :if={@status == :live and @login_url}
          id="app-open-new-tab"
          data-qa="app_open_new_tab"
          href={@login_url}
          target="_blank"
          rel="noopener"
          class={secondary_button()}
        >
          <.icon name="pi-arrow-square-out" class="size-[15px]" /> Open in new tab
        </a>
      </div>

      <p :if={@error} data-qa="app_error" class="px-5 pt-3 text-sm text-red-600 dark:text-red-400">
        {@error}
      </p>

      <p
        :if={@status == :no_pr}
        data-qa="app_no_pr"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        Every push to this task's pull request is deployed to an address of its own, shown here signed in. Rail opens
        the pull request once the engineer's first round passes CI.
      </p>

      <p
        :if={@status == :deploying}
        data-qa="app_deploying"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        Deploying the latest commit. This shows the app once it serves that commit, usually within a few minutes of the push.
      </p>

      <p
        :if={@status == :gone}
        data-qa="app_gone"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        This task has no worktree any more, so there is nothing to show.
      </p>

      <div :if={@status == :live} class="p-5 flex flex-col gap-3">
        <div class="flex flex-col overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-900">
          <div class="flex items-center gap-2 px-3 py-2 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60">
            <button
              type="button"
              title="Back"
              aria-label="Back"
              data-qa="app_back"
              phx-click="app_navigate"
              phx-value-to="back"
              phx-target={@target}
              class="p-1 rounded-md text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 cursor-pointer"
            >
              <.icon name="pi-arrow-left" class="size-4" />
            </button>
            <button
              type="button"
              title="Reload"
              aria-label="Reload"
              data-qa="app_reload"
              phx-click="app_navigate"
              phx-value-to="reload"
              phx-target={@target}
              class="p-1 rounded-md text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 cursor-pointer"
            >
              <.icon name="pi-arrow-clockwise" class="size-4" />
            </button>
            <span
              data-qa="app_url"
              class="flex-1 min-w-0 truncate rounded-md border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-900/70 px-2.5 py-1 font-mono text-[11px] text-slate-500 dark:text-slate-400"
            >
              {@path}
            </span>
            <.design_comment_control
              commenting={@commenting}
              disabled_reason={if !@commentable, do: "Comments open once the task reaches Review."}
              target={@target}
            />
          </div>
          <div
            id="app-screen"
            data-qa="app_screen"
            phx-hook="AppInput"
            data-commenting={to_string(@commenting)}
            phx-mounted={JS.ignore_attributes(["style"])}
            tabindex="0"
            class={[
              "relative w-full mx-auto aspect-video bg-slate-900 outline-none focus-visible:ring-2 focus-visible:ring-blue-500",
              @commenting && "cursor-crosshair",
              !@commenting && "cursor-default"
            ]}
          >
            <img
              id="app-screencast"
              phx-hook="BrowserScreencast"
              phx-update="ignore"
              phx-mounted={JS.ignore_attributes(["src", "data-live"])}
              alt="The app as it is now"
              draggable="false"
              class="peer absolute inset-0 size-full object-contain select-none pointer-events-none"
            />
            <div class="absolute inset-0 flex items-center justify-center bg-slate-900 peer-data-[live=true]:hidden">
              <span class="font-mono text-[11.5px] text-slate-400">Waiting for the app to paint.</span>
            </div>
            <div
              :if={@draft}
              data-qa="app_picked"
              class="absolute pointer-events-none rounded-sm ring-2 ring-blue-500 bg-blue-500/10"
              style={box_style(@draft.element)}
            />
            <.form
              :if={@draft}
              for={%{}}
              as={:app_comment}
              id="app-comment-form"
              data-qa="app_comment_form"
              phx-submit="save_app_comment"
              phx-change="app_comment_change"
              phx-target={@target}
              data-app-ui
              style={popover_style(@draft.element)}
              class="absolute z-10 w-80 max-w-[90%] flex flex-col gap-2 rounded-xl border border-blue-200 dark:border-blue-900 bg-white dark:bg-slate-900 shadow-lg p-3 cursor-auto"
            >
              <p
                class="text-xs text-slate-600 dark:text-slate-300 truncate"
                title={@draft.element.selector}
              >
                On
                <span class="font-semibold text-slate-900 dark:text-slate-100">{element_name(
                  @draft.element
                )}</span>
                at <code class="font-mono">{path(@draft.element.url)}</code>
              </p>
              <textarea
                name="body"
                rows="3"
                phx-debounce="300"
                data-qa="app_comment_body"
                placeholder="What should change here?"
                class="block w-full rounded-md border-slate-200 dark:border-slate-700 dark:bg-slate-900 text-sm"
              >{@draft.body}</textarea>
              <div class="flex gap-2 justify-end">
                <button
                  type="button"
                  phx-click="cancel_app_comment"
                  phx-target={@target}
                  class={secondary_button()}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  data-qa="app_comment_save"
                  class="px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer"
                >
                  Comment
                </button>
              </div>
            </.form>
          </div>
        </div>

        <ol :if={@comments != []} data-qa="app_comments" class="flex flex-col gap-2">
          <li
            :for={comment <- @comments}
            data-qa="app_comment"
            class="flex items-start gap-3 rounded-lg border border-slate-200 dark:border-slate-700 p-3 text-sm"
          >
            <div class="min-w-0 flex-1">
              <p class="text-xs text-slate-500 dark:text-slate-400 truncate">
                {comment.label} · <code class="font-mono">{comment.selector}</code>
              </p>
              <p class="text-slate-900 dark:text-slate-100 whitespace-pre-wrap">{comment.body}</p>
            </div>
            <button
              type="button"
              data-qa="app_comment_remove"
              phx-click="remove_screen_comment"
              phx-value-id={comment.id}
              phx-target={@target}
              class="shrink-0 text-xs text-slate-500 hover:text-red-600 cursor-pointer"
            >
              Remove
            </button>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp status(false, _preview), do: :no_pr
  defp status(true, nil), do: :deploying
  defp status(true, %Preview{status: status}), do: status

  defp status_label(:no_pr), do: "No pull request yet"
  defp status_label(:deploying), do: "Deploying…"
  defp status_label(:live), do: "Live"
  defp status_label(:gone), do: "Gone"

  defp status_class(:live), do: "text-green-600 dark:text-green-400"
  defp status_class(:deploying), do: "text-blue-600 dark:text-blue-400"
  defp status_class(_no_pr_or_gone), do: "text-slate-500 dark:text-slate-400"

  defp host(url), do: URI.parse(url).host

  defp secondary_button do
    "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
  end

  # The page's own address, without the port it happens to run on.
  defp path(nil), do: "about:blank"

  defp path(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, path: path, query: query} when scheme in ["http", "https"] ->
        (path || "/") <> if(query, do: "?" <> query, else: "")

      %URI{} ->
        url
    end
  end

  # What a person would call the element: what it says, or its tag when it says nothing.
  defp element_name(%{text: "" <> text}) when text != "", do: ~s("#{text}")
  defp element_name(%{tag: tag}), do: "<#{tag}>"

  # The comment box sits under the element, or over it when the element is low on the page, and never off its side.
  defp popover_style(%{x: x, y: y, height: height}) do
    left = "left: #{min(max(x, 0), 1300) / 19.2}%;"

    if y + height > 700,
      do: "#{left} bottom: #{(1080 - max(y, 0)) / 10.8 + 1}%;",
      else: "#{left} top: #{(y + height) / 10.8 + 1}%;"
  end

  # The element's box in the tab's 1920x1080 pixels, as a share of the picture.
  defp box_style(%{x: x, y: y, width: width, height: height}) do
    "left: #{x / 19.2}%; top: #{y / 10.8}%; width: #{width / 19.2}%; height: #{height / 10.8}%;"
  end
end

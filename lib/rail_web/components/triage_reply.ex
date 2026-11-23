defmodule RailWeb.Components.TriageReply do
  @moduledoc """
  A thread's one reply, with what stops it: a pass running or failed, or a Send that stopped partway.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Thread

  attr :thread, Thread, required: true
  attr :author_name, :string, required: true
  attr :locked, :boolean, required: true, doc: "the agent is working or the thread was dismissed"

  def triage_reply(assigns) do
    thread = assigns.thread
    running = thread.status == :triaging
    posted = is_struct(thread.reply_posted_at, DateTime)
    forwarded = Thread.forwarded?(thread)

    assigns =
      assigns
      |> assign(:running, running)
      |> assign(:posted, posted)
      |> assign(:show_error, is_binary(thread.error) and not running)
      |> assign(
        :show_no_response,
        thread.items == [] and is_nil(thread.error) and not running and is_binary(thread.no_response_reason)
      )
      |> assign(
        :show_nothing,
        thread.items == [] and is_nil(thread.reply_text) and not running and is_nil(thread.no_response_reason)
      )
      |> assign(:show_forwarded, forwarded)
      |> assign(:show_reply, not forwarded and (posted or is_binary(thread.reply_text)))

    ~H"""
    <div id="triage-reply-panel" class="space-y-4">
      <p
        :if={@running}
        id="triage-running"
        class="flex items-center gap-2 rounded-lg border border-blue-300/50 bg-blue-500/10 px-3 py-2 text-[12.5px] text-blue-800 dark:text-blue-200"
      >
        <.icon name="pi-circle-notch" class="size-3.5 shrink-0 animate-spin" />
        <span>
          <b>Running</b>
          · the agent is updating the reply and the tickets. Editing and Send wait until it finishes.
        </span>
      </p>
      <div
        :if={@thread.send_error}
        id="triage-send-error"
        role="alert"
        class="flex items-start gap-2 rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-3 py-2 text-[12.5px] text-red-800 dark:text-red-200"
      >
        <.icon name="pi-warning-circle" class="size-4 mt-px shrink-0" />
        <span class="min-w-0 break-words"><b>Send stopped partway.</b> {@thread.send_error}</span>
      </div>
      <div
        :if={@show_error}
        id="triage-error"
        role="alert"
        class="flex items-start gap-2 rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-3 py-2 text-[12.5px] text-red-800 dark:text-red-200"
      >
        <.icon name="pi-warning-circle" class="size-4 mt-px shrink-0" />
        <span class="min-w-0 break-words">
          <b>Triage did not finish.</b> {@thread.error} Tell the agent in the chat to try again.
        </span>
      </div>
      <p
        :if={@show_no_response}
        id="triage-no-response"
        class="text-[13px] break-words text-slate-700 dark:text-slate-300"
      >
        Rail read this as: {@thread.no_response_reason}. If it needs a response, say so in the chat.
      </p>
      <p
        :if={@show_nothing}
        id="triage-nothing"
        class="text-[13px] text-slate-500 dark:text-slate-400"
      >
        Nothing is drafted yet.
      </p>
      <p
        :if={@show_forwarded}
        id="triage-forwarded"
        class="flex items-center gap-2 text-[12.5px] text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-lock-simple" class="size-3.5 shrink-0" />
        Support already replied in Intercom. Nothing reaches the tracker until you create it.
      </p>
      <form
        :if={@show_reply}
        id="triage-reply-form"
        phx-change="update_reply"
        class={[
          "rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 focus-within:ring-1 focus-within:ring-blue-500",
          (@locked or @posted) && "opacity-60"
        ]}
      >
        <div class="flex items-center gap-2 px-3 pt-2 text-[11px] min-w-0">
          <label for="triage-reply" class="truncate font-semibold text-slate-700 dark:text-slate-300">
            Reply in Slack as {@author_name}
          </label>
          <span
            :if={!@posted}
            class="shrink-0 px-1.5 rounded border border-dashed border-slate-400 text-[10.5px] font-semibold text-slate-500 dark:text-slate-400"
          >
            Draft, not sent
          </span>
          <span
            :if={@posted}
            id="triage-reply-posted"
            class="shrink-0 inline-flex items-center gap-1 px-1.5 rounded border border-emerald-500/60 text-[10.5px] font-semibold text-emerald-600 dark:text-emerald-400"
          >
            <.icon name="pi-check-circle-fill" class="size-3" />Posted by {name(
              @thread.reply_posted_by
            )} at <.local_time id="triage-reply-posted-at" at={@thread.reply_posted_at} />
          </span>
        </div>
        <textarea
          id="triage-reply"
          name="thread[reply_text]"
          rows="4"
          phx-debounce="400"
          readonly={@locked or @posted}
          class="block w-full resize-y border-0 bg-transparent px-3 py-2 text-[13px] leading-relaxed break-words text-slate-900 dark:text-slate-100 focus:outline-none"
        >{@thread.reply_text}</textarea>
        <p :if={!@posted} class="px-3 pb-2 text-[11px] text-slate-500 dark:text-slate-400">
          Rail adds the new tickets' links when it posts.
        </p>
      </form>
    </div>
    """
  end

  defp name(%{name: name}) when is_binary(name) and name != "", do: name
  defp name(%{login: login}) when is_binary(login), do: login
  defp name(_gone), do: "someone"
end

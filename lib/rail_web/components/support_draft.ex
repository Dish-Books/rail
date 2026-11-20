defmodule RailWeb.Components.SupportDraft do
  @moduledoc """
  The agent's draft for a support conversation, docked under it: what goes to dev, the reply,
  and the buttons that send both and mark the conversation done.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item

  attr :conversation, Conversation, required: true
  attr :linked, :boolean, required: true
  attr :author_name, :string, required: true

  def support_draft(assigns) do
    conversation = assigns.conversation
    drafting = Conversation.drafting?(conversation)
    posted = is_struct(conversation.reply_posted_at, DateTime)
    to_forward = Conversation.to_forward(conversation)
    done = conversation.status == :done
    no_draft = is_nil(conversation.drafted_at) and not drafting

    assigns =
      assigns
      |> assign(:drafting, drafting)
      |> assign(:posted, posted)
      |> assign(:to_forward, to_forward)
      |> assign(:tracked, Enum.filter(conversation.items, &Item.tracked?/1))
      |> assign(:show_done, done)
      |> assign(:show_no_draft, not done and no_draft)
      |> assign(:show_sent, not done and not no_draft and posted and to_forward == [])
      |> assign(:show_draft, not done and not no_draft and not (posted and to_forward == []))
      |> assign(:send_label, Conversation.send_label(conversation))
      |> assign(:send_disabled, drafting or (not posted and (not assigns.linked or blank?(conversation.reply_text))))
      |> assign(:forwarded_count, forwarded_count(conversation))
      |> assign(:hint, hint(conversation, assigns.linked, assigns.author_name, length(to_forward)))

    ~H"""
    <div
      :if={@show_done}
      id="support-draft"
      class="border-t border-slate-200 dark:border-slate-700 px-4 py-3"
    >
      <p
        id="support-done"
        class="flex flex-wrap items-center gap-x-2 text-[12.5px] text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-check-circle-fill" class="size-3.5 text-emerald-500" />
        <span :if={@conversation.done_by}>
          Marked done by {name(@conversation.done_by)} at
          <.local_time id="done-at" at={@conversation.done_at} />.
        </span>
        <span :if={!@conversation.done_by}>Closed in Intercom before it was imported.</span>
        <span>A new message from the customer brings it back to Waiting.</span>
      </p>
    </div>

    <div
      :if={@show_no_draft}
      id="support-draft"
      class="border-t-2 border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/40 px-4 py-4 flex flex-wrap items-center gap-3"
    >
      <.icon name="pi-sparkle" class="size-4.5 text-slate-400" />
      <p id="support-no-draft" class="min-w-0 flex-1 text-[13px] text-slate-600 dark:text-slate-300">
        No draft yet. The agent has not read this conversation.
      </p>
      <span class="ml-auto flex items-center gap-2">
        <.button phx-click="mark_done" id="mark-done-button">
          <.icon name="pi-check-bold" class="size-3.5" />Mark done
        </.button>
        <.button variant="primary" phx-click="draft" id="draft-reply-button">
          <.icon name="pi-sparkle-bold" class="size-3.5" />Draft a reply
        </.button>
      </span>
    </div>

    <div
      :if={@show_sent}
      id="support-draft"
      class="border-t border-slate-200 dark:border-slate-700 px-4 py-3 flex flex-wrap items-center gap-3"
    >
      <p
        id="support-sent"
        class="min-w-0 flex-1 flex items-center gap-2 text-[12.5px] text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-check-circle-fill" class="size-3.5 text-emerald-500" />
        <span>
          Sent by {name(@conversation.reply_posted_by)} at
          <.local_time id="reply-posted-at" at={@conversation.reply_posted_at} /><span :if={
            @forwarded_count > 0
          }> and forwarded {@forwarded_count} to dev</span>. It stays in Waiting until you mark it done.
        </span>
      </p>
      <.button variant="primary" phx-click="mark_done" id="mark-done-button" class="ml-auto">
        <.icon name="pi-check-bold" class="size-3.5" />Mark done
      </.button>
    </div>

    <div
      :if={@show_draft}
      id="support-draft"
      class="border-t-2 border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/40 px-4 pt-3 pb-3 space-y-3"
    >
      <div :if={@conversation.items != []} id="support-forward-list">
        <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-1">
          Forward to dev · {length(@to_forward)}
        </p>
        <ul class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 divide-y divide-slate-200 dark:divide-slate-700">
          <li
            :for={item <- @to_forward}
            id={"support-item-#{item.id}"}
            data-qa="support-item"
            class="flex items-center gap-2 px-3 py-1.5 min-w-0"
          >
            <span class="flex items-center justify-center h-5 w-5 shrink-0 rounded-full bg-slate-200 dark:bg-slate-700 text-[11px] font-bold text-slate-900 dark:text-slate-100">
              {item.position}
            </span>
            <.triage_verdict kind={item.kind} />
            <span
              title={item.title}
              class="text-[13px] font-medium truncate min-w-0 text-slate-900 dark:text-slate-100"
            >
              {item.title}
            </span>
            <span class="ml-auto flex items-center gap-3 shrink-0">
              <.triage_verdict
                id={"support-verdict-#{item.id}"}
                kind={item.kind}
                verdict={item.verdict}
              />
              <span :if={@posted} class="text-[11px] text-slate-500">Not forwarded yet</span>
            </span>
          </li>
          <li
            :if={@tracked != []}
            id="support-tracked"
            class="flex flex-wrap items-center gap-x-2 gap-y-1 px-3 py-1.5 text-[12px] text-slate-500"
          >
            <.icon name="pi-caret-right" class="size-3" />
            <span>{length(@tracked)} not forwarded:</span>
            <span
              :for={item <- @tracked}
              id={"support-tracked-#{item.id}"}
              class="inline-flex items-center gap-1.5"
            >
              item {item.position} is tracked in
              <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded border border-blue-300 dark:border-blue-800 text-[11px] font-semibold text-blue-700 dark:text-blue-300 whitespace-nowrap">
                <.icon name="pi-link-simple" class="size-3" /><span class="font-mono">{item.existing_issue.identifier}</span>
                · {Issue.state_label(item.existing_issue.state)}
              </span>
            </span>
          </li>
        </ul>
      </div>

      <.form
        for={Conversation.draft_changeset(@conversation, %{})}
        id="support-reply-form"
        phx-change="update_reply"
        class={[
          "rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 focus-within:ring-1 focus-within:ring-blue-500",
          (@drafting or @posted) && "opacity-60"
        ]}
      >
        <div class="flex items-center gap-2 px-3 pt-2 text-[11px] text-slate-500 min-w-0">
          <label for="support-reply" class="truncate font-semibold text-slate-700 dark:text-slate-300">
            Reply as {@author_name}
          </label>
          <span
            :if={!@posted}
            class="shrink-0 px-1.5 rounded border border-dashed border-slate-400 text-[10.5px] font-semibold text-slate-400"
          >
            Draft, not sent
          </span>
          <span
            :if={@posted}
            class="shrink-0 inline-flex items-center gap-1 px-1.5 rounded border border-emerald-500/60 text-[10.5px] font-semibold text-emerald-600 dark:text-emerald-400"
          >
            <.icon name="pi-check-circle-fill" class="size-3" />Posted at
            <.local_time id="reply-posted-badge" at={@conversation.reply_posted_at} />
          </span>
        </div>
        <textarea
          id="support-reply"
          name="conversation[reply_text]"
          rows="6"
          phx-debounce="400"
          readonly={@drafting or @posted}
          class="block w-full resize-none border-0 bg-transparent px-3 py-2 text-[13px] leading-relaxed text-slate-900 dark:text-slate-100 focus:outline-none"
        >{@conversation.reply_text}</textarea>
      </.form>

      <p
        :if={!@linked and !@posted}
        id="support-link-prompt"
        class="flex items-center gap-2 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-800 px-3 py-2 text-[12.5px] text-slate-700 dark:text-slate-200"
      >
        <.icon name="pi-link-break" class="size-4 text-slate-400" />
        <span>Link your Intercom account to send this as yourself.</span>
        <.link
          navigate={~p"/settings/connected-accounts"}
          id="link-intercom"
          class="ml-auto whitespace-nowrap font-semibold text-blue-600 dark:text-blue-400 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          Link Intercom
        </.link>
      </p>
      <p
        :if={@drafting}
        id="support-drafting"
        class="flex items-center gap-2 rounded-lg border border-blue-300/50 bg-blue-500/10 px-3 py-2 text-[12.5px] text-blue-800 dark:text-blue-200"
      >
        <.icon name="pi-circle-notch" class="size-3.5 animate-spin" />
        <span><b>Running</b> · the agent is reading the conversation and updating the draft.</span>
      </p>
      <div
        :if={is_binary(@conversation.agent_error) and !@drafting}
        id="support-agent-error"
        class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-3 py-2 text-[12.5px] text-red-800 dark:text-red-200 flex items-start gap-2"
      >
        <.icon name="pi-warning-circle" class="size-4 mt-px shrink-0" />
        <span class="min-w-0 break-words"><b>The agent did not finish.</b> {@conversation.agent_error}</span>
        <.button size="sm" phx-click="draft" id="try-again-button" class="ml-auto shrink-0">Try again</.button>
      </div>
      <div
        :if={@conversation.send_error}
        id="support-send-error"
        class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-3 py-2 text-[12.5px] text-red-800 dark:text-red-200 flex items-start gap-2"
      >
        <.icon name="pi-warning-circle" class="size-4 mt-px shrink-0" />
        <span>{@conversation.send_error} Forward again; the reply is not posted twice.</span>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <span id="support-send-hint" class="min-w-0 text-xs text-slate-500 dark:text-slate-400">{@hint}</span>
        <span class="ml-auto flex flex-wrap justify-end items-center gap-2">
          <%!-- A forward still owed after the reply posted is finished first, so no item is stranded. --%>
          <.button :if={!@posted} phx-click="mark_done" id="mark-done-button">
            <.icon name="pi-check-bold" class="size-3.5" />Mark done
          </.button>
          <.button
            variant="primary"
            phx-click="send"
            phx-disable-with="Sending…"
            id="support-send-button"
            disabled={@send_disabled}
          >
            <.icon
              name={if @posted, do: "pi-arrow-bend-up-right-bold", else: "pi-paper-plane-tilt-bold"}
              class="size-3.5"
            />{@send_label}
          </.button>
        </span>
      </div>
    </div>
    """
  end

  defp hint(%Conversation{} = conversation, linked, author_name, count) do
    cond do
      Conversation.drafting?(conversation) -> "Send waits until the agent finishes."
      is_struct(conversation.reply_posted_at, DateTime) -> "The reply is already in Intercom."
      is_binary(conversation.agent_error) and blank?(conversation.reply_text) -> "The agent has not drafted a reply yet."
      is_binary(conversation.agent_error) -> "The draft above is from the agent's last finished run."
      not linked -> "Posts in Intercom as you, then forwards to triage."
      count == 0 -> "Posts in Intercom as #{author_name}."
      true -> "Posts in Intercom as #{author_name}, then forwards #{count} to triage."
    end
  end

  # The items this round's Send forwarded, for the line that says it was sent.
  defp forwarded_count(%Conversation{reply_posted_at: %DateTime{} = posted_at, items: items}),
    do: Enum.count(items, &(is_struct(&1.forwarded_at, DateTime) and DateTime.compare(&1.forwarded_at, posted_at) != :lt))

  defp forwarded_count(%Conversation{}), do: 0

  defp blank?(text), do: is_nil(text) or String.trim(text) == ""

  defp name(%{name: name}) when is_binary(name) and name != "", do: name
  defp name(%{login: login}) when is_binary(login), do: login
  defp name(_gone), do: "someone"
end

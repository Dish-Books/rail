defmodule RailWeb.Components.TriageSendBar do
  @moduledoc """
  The one button that adds a thread's follow-ups, creates its tickets and posts its reply, and what it will do.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Thread

  attr :thread, Thread, required: true
  attr :slack_linked, :boolean, required: true
  attr :error, :string, default: nil, doc: "a Send or edit the page refused"

  def triage_send_bar(assigns) do
    thread = assigns.thread
    running = thread.status == :triaging
    label = Thread.send_label(thread)
    unlinked = Thread.reply_draft?(thread) and not assigns.slack_linked

    assigns =
      assigns
      |> assign(:send_label, label)
      |> assign(:send_disabled, running or unlinked)
      |> assign(:show_link_prompt, unlinked)
      |> assign(:show_sent, is_nil(label) and not running and Enum.any?(thread.items, &is_struct(&1.sent_at, DateTime)))
      |> assign(:show_dismiss, thread.status != :done)
      |> assign(:hint, calculate_hint(thread, label, running))
      |> assign(:sent_counts, calculate_sent_counts(thread))

    ~H"""
    <div
      id="triage-send-bar"
      class="border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-6 py-3 space-y-2"
    >
      <p
        :if={@show_link_prompt}
        id="triage-link-prompt"
        class="flex items-center gap-2 text-[12.5px] text-slate-700 dark:text-slate-200"
      >
        <.icon name="pi-link-break" class="size-4 shrink-0 text-slate-400" />
        <span>Connect Slack to post as yourself.</span>
        <.link
          navigate={~p"/settings/connected-accounts"}
          id="connect-slack"
          class="ml-auto whitespace-nowrap font-semibold text-blue-600 dark:text-blue-400 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          Connect Slack
        </.link>
      </p>
      <p :if={@error} id="triage-refused" role="alert" class="text-xs text-red-600 dark:text-red-400">
        {@error}
      </p>
      <p
        :if={@show_sent}
        id="triage-sent"
        class="flex items-center gap-2 text-[12.5px] text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-check-circle-fill" class="size-3.5 shrink-0 text-emerald-500" />
        <span :if={@thread.reply_posted_at}>
          Sent by {name(@thread.reply_posted_by)} at
          <.local_time id="triage-sent-at" at={@thread.reply_posted_at} /><span :if={@sent_counts}>: {@sent_counts}</span>. A new message in the thread brings it back.
        </span>
        <span :if={!@thread.reply_posted_at}>
          Sent<span :if={@sent_counts}>: {@sent_counts}</span>. A new message in the thread brings it back.
        </span>
      </p>
      <div :if={!@show_sent} class="flex flex-wrap items-center gap-3">
        <span id="triage-send-hint" class="min-w-0 text-xs text-slate-500 dark:text-slate-400">{@hint}</span>
        <span class="ml-auto flex min-w-0 max-w-full items-center gap-2">
          <.button :if={@show_dismiss} size="sm" phx-click="dismiss_thread" id="dismiss-thread-button">
            Dismiss thread
          </.button>
          <.button
            :if={@send_label}
            variant="primary"
            phx-click="send"
            phx-disable-with="Sending…"
            id="triage-send-button"
            disabled={@send_disabled}
            title={@send_label}
            class="min-w-0"
          >
            <.icon name="pi-paper-plane-tilt-bold" class="size-3.5 shrink-0" />
            <span class="truncate">{@send_label}</span>
          </.button>
        </span>
      </div>
    </div>
    """
  end

  defp calculate_hint(_thread, _label, true), do: "Send waits until the agent finishes."
  defp calculate_hint(_thread, nil, false), do: "Nothing to send yet."

  defp calculate_hint(%Thread{} = thread, _label, false) do
    comments = Enum.map(Thread.to_update(thread), & &1.existing_issue.identifier)
    creates = length(Thread.to_create(thread))

    steps =
      Enum.reject(
        [
          comments != [] && "comments on #{Enum.join(comments, ", ")}",
          creates > 0 && "creates #{creates} #{if creates == 1, do: "ticket", else: "tickets"} in #{thread.project.key}"
        ],
        &(&1 == false)
      )

    posts = if Thread.reply_draft?(thread), do: "posts in #{Thread.source_label(thread)} as you"

    case {steps, posts} do
      {[], posts} -> sentence(posts) <> "."
      {steps, nil} -> sentence(Enum.join(steps, " and ")) <> "."
      {steps, posts} -> sentence(Enum.join(steps, " and ")) <> ", then " <> posts <> "."
    end
  end

  # "2 tickets created, 1 follow-up added, 1 ignored", or nil when the round had none of them.
  defp calculate_sent_counts(%Thread{items: items}) do
    counts =
      Enum.reject(
        [
          count(Enum.count(items, &is_binary(&1.created_issue_id)), "ticket created", "tickets created"),
          count(Enum.count(items, &is_struct(&1.followup_posted_at, DateTime)), "follow-up added", "follow-ups added"),
          count(Enum.count(items, & &1.ignored), "ignored", "ignored")
        ],
        &is_nil/1
      )

    if counts != [], do: Enum.join(counts, ", ")
  end

  defp count(0, _one, _many), do: nil
  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp sentence(text), do: String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)

  defp name(%{name: name}) when is_binary(name) and name != "", do: name
  defp name(%{login: login}) when is_binary(login), do: login
  defp name(_gone), do: "someone"
end

defmodule RailWeb.Components.SupportConversation do
  @moduledoc """
  The middle pane of the Support page: an Intercom conversation, every message labeled by who sent it.
  """
  use RailWeb, :html

  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Message

  @kinds %{
    customer: %{
      label: "Customer",
      tag: "bg-sky-100 dark:bg-sky-950 text-sky-800 dark:text-sky-200",
      avatar: "rounded-full bg-sky-600 text-white",
      box: "border-l-[3px] border-transparent"
    },
    teammate: %{
      label: "Teammate",
      tag: "bg-indigo-100 dark:bg-indigo-950 text-indigo-800 dark:text-indigo-200",
      avatar: "rounded-full bg-indigo-500 text-white",
      box: "border-l-[3px] border-indigo-500/60 bg-indigo-500/5"
    },
    bot: %{
      label: "BOT",
      tag: "bg-slate-200 dark:bg-slate-700 text-slate-600 dark:text-slate-300",
      avatar: "rounded-lg bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200",
      box: "border-l-[3px] border-transparent"
    },
    note: %{
      label: "Internal note",
      tag: "bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200",
      avatar: "rounded-full bg-indigo-500 text-white",
      box: "border border-dashed border-slate-400 dark:border-slate-500 bg-slate-100 dark:bg-slate-800/70"
    }
  }

  attr :conversation, Conversation, required: true

  def support_conversation(assigns) do
    conversation = assigns.conversation

    assigns =
      assigns
      |> assign(:inbox_url, IntercomWorkspace.inbox_url(conversation.intercom_workspace, conversation.external_id))
      |> assign(:count, length(conversation.messages))
      |> assign(
        :entries,
        Enum.map(conversation.messages, fn message ->
          %{
            message: message,
            style: Map.fetch!(@kinds, message.kind),
            images: Enum.filter(message.attachments, &Message.image?/1),
            files: Enum.reject(message.attachments, &Message.image?/1)
          }
        end)
      )

    ~H"""
    <section
      id="support-conversation"
      data-qa="support-conversation"
      class="flex-1 flex flex-col min-h-0"
    >
      <div class="px-5 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400 min-w-0">
          <.project_badge project={@conversation.project} />
          <span class="truncate">
            <span class="font-semibold text-slate-700 dark:text-slate-300">
              {@conversation.customer_name || "Customer"}
            </span>
            <span :if={@conversation.customer_email}>· {@conversation.customer_email}</span>
          </span>
          <span class="shrink-0">· {@count} {if @count == 1, do: "message", else: "messages"}</span>
          <a
            href={@inbox_url}
            target="_blank"
            rel="noopener noreferrer"
            id="open-in-intercom"
            class="ml-auto shrink-0 inline-flex items-center gap-1 font-semibold text-blue-600 dark:text-blue-400 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-arrow-square-out" class="size-3.5" />Open in Intercom
          </a>
        </div>
        <h2
          id="support-conversation-title"
          class="mt-2 text-lg font-bold leading-snug break-words text-slate-900 dark:text-slate-100"
        >
          {Conversation.title_or_preview(@conversation)}
        </h2>
      </div>

      <div id="support-messages" class="flex-1 min-h-0 overflow-y-auto px-3 py-3 space-y-1.5">
        <div
          :for={entry <- @entries}
          id={"support-message-#{entry.message.id}"}
          data-qa="support-message"
          data-kind={entry.message.kind}
          class={["flex gap-2.5 rounded-lg pl-2 pr-2.5 py-2", entry.style.box]}
        >
          <span class={[
            "flex items-center justify-center h-7 w-7 shrink-0 text-[10px] font-semibold",
            entry.style.avatar
          ]}>
            <.icon :if={entry.message.kind == :bot} name="pi-robot" class="size-4" />
            <span :if={entry.message.kind != :bot}>{Message.initials(entry.message)}</span>
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-[13px] text-slate-900 dark:text-slate-100 flex flex-wrap items-center gap-x-1.5 min-w-0">
              <span class="font-semibold break-all">{entry.message.author_name}</span>
              <span class={[
                "inline-flex items-center gap-1 px-1 rounded text-[10px] font-semibold",
                entry.style.tag
              ]}>
                <.icon :if={entry.message.kind == :note} name="pi-lock-simple" class="size-2.5" />{entry.style.label}
              </span>
              <.local_time
                id={"support-time-#{entry.message.id}"}
                at={entry.message.posted_at}
                class="text-xs text-slate-500 dark:text-slate-400"
              />
            </p>
            <p
              id={"support-text-#{entry.message.id}"}
              class="text-[13px] leading-relaxed text-slate-800 dark:text-slate-200 whitespace-pre-line break-words"
              phx-no-format
            >{entry.message.text}</p>
            <a
              :for={{file, index} <- Enum.with_index(entry.images)}
              href={file.url}
              target="_blank"
              rel="noopener noreferrer"
              id={"support-image-#{entry.message.id}-#{index}"}
              class="mt-2 block w-fit max-w-full rounded-lg focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              <img
                src={file.url}
                alt={file.name}
                class="max-w-[300px] max-h-[300px] w-auto rounded-lg border border-slate-300 dark:border-slate-600"
              />
            </a>
            <a
              :for={{file, index} <- Enum.with_index(entry.files)}
              href={file.url}
              target="_blank"
              rel="noopener noreferrer"
              id={"support-file-#{entry.message.id}-#{index}"}
              class="mt-2 mr-2 inline-flex max-w-full items-center gap-2 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800 px-2.5 py-1.5 text-[12px] text-slate-800 dark:text-slate-200 hover:border-slate-400 focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-paperclip" class="size-4 shrink-0" />
              <span class="font-medium truncate">{file.name || "Attachment"}</span>
              <span :if={file.size} class="shrink-0 text-slate-500">{max(div(file.size, 1024), 1)} KB</span>
              <.icon name="pi-download-simple" class="size-3.5 shrink-0 text-slate-400" />
            </a>
          </div>
        </div>
      </div>
    </section>
    """
  end
end

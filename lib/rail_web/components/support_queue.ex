defmodule RailWeb.Components.SupportQueue do
  @moduledoc """
  The left pane of the Support page: the conversations in one filter, newest message first.
  """
  use RailWeb, :html

  alias Rail.Support.Schemas.Conversation

  attr :conversations, :list, required: true
  attr :counts, :map, required: true
  attr :filter, :atom, required: true
  attr :selected_id, :string, default: nil
  attr :workspace_names, :list, required: true
  attr :now, DateTime, required: true

  def support_queue(assigns) do
    assigns =
      assigns
      |> assign(:workspaces_line, Enum.join(assigns.workspace_names, " · "))
      |> assign(:empty_message, empty_message(assigns.filter))

    ~H"""
    <aside
      id="support-queue"
      data-qa="support-queue"
      class="w-[330px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <div class="px-4 pt-4 pb-3 space-y-3 border-b border-slate-200 dark:border-slate-700">
        <.segmented_control
          id="support-filter"
          options={[
            waiting: "Waiting · #{@counts.waiting}",
            drafting: "Drafting · #{@counts.drafting}",
            done: "Done · #{@counts.done}"
          ]}
          selected={@filter}
          event="filter"
          value_name="filter"
          class="whitespace-nowrap"
        />
        <p
          :if={@workspace_names != []}
          id="support-workspaces"
          class="flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 min-w-0"
        >
          <.icon name="pi-chats-circle" class="size-3.5" /><span class="truncate">Intercom · {@workspaces_line}</span>
        </p>
      </div>

      <div class="flex-1 overflow-y-auto p-2 space-y-1">
        <div
          :if={@conversations == []}
          id="support-queue-empty"
          class="m-2 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-10 text-center"
        >
          <.icon name="pi-headset-fill" class="size-10 text-slate-400 dark:text-slate-500" />
          <p class="mt-2 text-sm font-semibold text-slate-700 dark:text-slate-300">
            {@empty_message}
          </p>
          <p
            :if={@workspace_names != []}
            class="mt-1 text-xs text-slate-500 dark:text-slate-400 break-words"
          >
            Intercom · {@workspaces_line} is connected. New conversations arrive here as customers write in.
          </p>
          <p :if={@workspace_names == []} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            No Intercom workspace is connected. An admin adds one in Settings, Intercom.
          </p>
        </div>

        <.link
          :for={conversation <- @conversations}
          patch={~p"/support/#{conversation.id}?#{[filter: @filter]}"}
          id={"support-row-#{conversation.id}"}
          data-qa="support-row"
          aria-current={if conversation.id == @selected_id, do: "true"}
          class={[
            "block rounded-xl px-3 py-2.5 focus-visible:outline-2 focus-visible:outline-blue-500",
            conversation.id == @selected_id && "bg-white dark:bg-slate-800 ring-1 ring-blue-500",
            conversation.id != @selected_id && "hover:bg-slate-100 dark:hover:bg-slate-800/70"
          ]}
        >
          <span class="flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 min-w-0">
            <span class="whitespace-nowrap shrink-0 max-w-[60%] truncate font-semibold text-slate-700 dark:text-slate-300">
              {conversation.customer_name || "Customer"}
            </span>
            <span :if={conversation.customer_email} class="truncate">· {conversation.customer_email}</span>
            <span class="ml-auto shrink-0 whitespace-nowrap font-mono">
              {format_age(
                DateTime.diff(@now, conversation.last_message_at || conversation.inserted_at)
              )}
            </span>
          </span>
          <span class={[
            "mt-1 block text-[13px] leading-snug line-clamp-2 break-words",
            conversation.id == @selected_id && "font-semibold text-slate-900 dark:text-slate-100",
            conversation.id != @selected_id && "font-medium text-slate-800 dark:text-slate-200"
          ]}>
            {Conversation.title_or_preview(conversation)}
          </span>
        </.link>
      </div>
    </aside>
    """
  end

  defp empty_message(:waiting), do: "No conversation is waiting on you."
  defp empty_message(:drafting), do: "The agent is not drafting anything."
  defp empty_message(:done), do: "No conversation is done yet."
end

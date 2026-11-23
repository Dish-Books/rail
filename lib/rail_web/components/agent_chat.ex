defmodule RailWeb.Components.AgentChat do
  @moduledoc """
  A chat with an agent beside its draft: the person's asks, the agent's answers, and what each turn changed.
  """
  use RailWeb, :html

  attr :id, :string, required: true, doc: "prefix of every id, such as `support-chat` or `triage-chat`"
  attr :key, :string, required: true, doc: "the record's id, so autoscroll restarts on another record"
  attr :lines, :list, required: true
  attr :running, :boolean, required: true
  attr :form, :any, required: true, doc: "the chat message changeset"
  attr :empty, :string, required: true
  attr :placeholder, :string, required: true
  attr :gone_author, :string, required: true, doc: "the name shown for a line whose author was deleted"
  attr :class, :any, default: nil
  slot :header, doc: "replaces the Agent title, such as triage's Chat / Thread switch"

  def agent_chat(assigns) do
    ~H"""
    <aside id={@id} data-qa={@id} class={["flex flex-col min-h-0", @class]}>
      <div class="px-4 py-3 border-b border-slate-200 dark:border-slate-700 flex items-center gap-2">
        <.icon :if={@header == []} name="pi-robot" class="size-4 text-slate-400" />
        <p :if={@header == []} class="text-sm font-bold text-slate-900 dark:text-slate-100">Agent</p>
        {render_slot(@header)}
        <span
          :if={@running}
          id={"#{@id}-running"}
          class="ml-auto inline-flex items-center gap-1 text-[11px] font-semibold text-blue-600 dark:text-blue-400"
        >
          <.icon name="pi-circle-notch" class="size-3 animate-spin" />Running
        </span>
      </div>
      <div
        id={"#{@id}-lines-#{@key}"}
        data-run-id={@key}
        phx-hook="ChatAutoscroll"
        class="flex-1 overflow-y-auto overflow-x-hidden px-4 py-4 space-y-4"
      >
        <p
          :if={@lines == []}
          id={"#{@id}-empty"}
          class="text-[13px] text-slate-500 dark:text-slate-400"
        >
          {@empty}
        </p>
        <div :for={line <- @lines} id={"#{@id}-#{line.id}"} data-qa={"#{@id}-line"}>
          <div :if={line.author == :agent} class="space-y-2">
            <p
              :if={line.changes}
              class="ml-8 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 flex items-center gap-2 px-3 py-1.5 text-xs text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-wrench" class="size-3.5 shrink-0" />
              <span class="font-medium text-slate-700 dark:text-slate-300 break-words">{line.changes}</span>
            </p>
            <div class="flex gap-2">
              <span class="flex items-center justify-center h-6 w-6 rounded-lg shrink-0 bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200">
                <.icon name="pi-robot" class="size-3.5" />
              </span>
              <.markdown
                class="min-w-0 break-words text-[13px] leading-relaxed text-slate-800 dark:text-slate-200"
                content={line.text}
              />
            </div>
          </div>
          <div
            :if={line.author == :person}
            class="w-fit max-w-[85%] ml-auto px-3 py-2 rounded-xl rounded-br-xs bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 text-slate-800 dark:text-slate-100 space-y-1"
          >
            <p class="text-[11px] font-semibold text-slate-500 dark:text-slate-400">
              {author(line.user, @gone_author)} ·
              <.local_time id={"#{@id}-time-#{line.id}"} at={line.inserted_at} />
            </p>
            <p class="text-[13px] whitespace-pre-line break-words">{line.text}</p>
          </div>
        </div>
      </div>
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-change="chat_change"
        phx-submit="chat"
        class="border-t border-slate-200 dark:border-slate-700 px-3 py-3"
      >
        <div class="flex items-end gap-2">
          <div class="flex-1 min-w-0 rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 focus-within:ring-1 focus-within:ring-blue-600 dark:focus-within:ring-blue-500 has-[textarea:disabled]:opacity-50">
            <textarea
              id={"#{@id}-text"}
              name="chat_message[text]"
              rows="2"
              disabled={@running}
              placeholder={@placeholder}
              aria-label="Message the agent"
              class="block w-full resize-none border-0 px-3 py-2 text-sm rounded-lg bg-transparent text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none"
            >{Ecto.Changeset.get_field(@form, :text)}</textarea>
          </div>
          <button
            type="submit"
            id={"#{@id}-send"}
            disabled={@running}
            aria-label="Send to the agent"
            class="inline-flex items-center justify-center h-9 w-9 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed shrink-0 shadow-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-arrow-up-bold" class="size-4" />
          </button>
        </div>
      </.form>
    </aside>
    """
  end

  defp author(%{name: name}, _gone) when is_binary(name) and name != "", do: name
  defp author(%{login: login}, _gone) when is_binary(login), do: login
  defp author(_gone_user, gone), do: gone
end

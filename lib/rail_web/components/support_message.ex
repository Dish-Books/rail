defmodule RailWeb.Components.SupportMessage do
  @moduledoc """
  The box at the foot of a support conversation that posts straight to the customer in Intercom,
  at any time and apart from the agent's draft.
  """
  use RailWeb, :html

  alias Rail.Support.Schemas.Conversation

  attr :conversation, Conversation, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :linked, :boolean, required: true
  attr :author_name, :string, required: true
  attr :error, :string, default: nil

  def support_message(assigns) do
    assigns = assign(assigns, :customer, assigns.conversation.customer_name || "the customer")

    ~H"""
    <.form
      for={@form}
      id="support-message-form"
      phx-change="message_change"
      phx-submit="send_message"
      class="shrink-0 border-t border-slate-200 dark:border-slate-700 px-3 py-3 space-y-2"
    >
      <p
        :if={@error}
        id="support-message-failed"
        role="alert"
        class="text-xs text-red-600 dark:text-red-400"
      >
        {@error}
      </p>
      <p
        :if={!@linked}
        id="support-message-link-prompt"
        class="flex items-center gap-2 text-[12.5px] text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-link-break" class="size-4 text-slate-400" />
        <span>Link your Intercom account to message {@customer} as yourself.</span>
        <.link
          navigate={~p"/settings/connected-accounts"}
          id="support-message-link-intercom"
          class="ml-auto whitespace-nowrap font-semibold text-blue-600 dark:text-blue-400 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          Link Intercom
        </.link>
      </p>
      <div class="flex items-end gap-2">
        <div class="flex-1 min-w-0 rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 focus-within:ring-1 focus-within:ring-blue-600 dark:focus-within:ring-blue-500 has-[textarea:disabled]:opacity-50">
          <textarea
            id="support-message-text"
            name={@form[:text].name}
            rows="2"
            disabled={!@linked}
            placeholder={"Message #{@customer} in Intercom as #{@author_name}"}
            aria-label={"Message #{@customer}"}
            class="block w-full resize-none border-0 px-3 py-2 text-sm rounded-lg bg-transparent text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none"
          >{@form[:text].value}</textarea>
        </div>
        <button
          type="submit"
          id="support-message-send"
          disabled={!@linked}
          phx-disable-with
          aria-label={"Send to #{@customer}"}
          title="Posts in Intercom now. The draft is left as it is."
          class="inline-flex items-center justify-center h-9 w-9 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed shrink-0 shadow-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-paper-plane-tilt-bold" class="size-4" />
        </button>
      </div>
    </.form>
    """
  end
end

defmodule RailWeb.Components.TestingPlace do
  @moduledoc """
  Where a ticket was tested: the environment and the platform, picked from a segmented control, and the device, typed.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  attr :issue, Issue, required: true
  attr :editable, :boolean, required: true
  attr :locked, :boolean, default: false, doc: "testing finished: the device reads as text"

  def testing_place(assigns) do
    assigns =
      assigns
      |> assign(:environments, for(e <- Issue.testing_environments(), do: {e, Issue.testing_environment_label(e)}))
      |> assign(:platforms, for(p <- Issue.testing_platforms(), do: {p, Issue.testing_platform_label(p)}))

    ~H"""
    <div id="testing-place" class="flex items-center gap-x-3 gap-y-2 flex-wrap min-w-0">
      <span class="text-sm font-semibold text-slate-900 dark:text-slate-100 mr-1">Where I tested</span>
      <.segmented_control
        id="testing-environment"
        options={@environments}
        selected={@issue.testing_environment}
        event="save_place"
        value_name="testing_environment"
        disabled={!@editable}
        role="group"
        aria-label="Environment"
      />
      <.segmented_control
        id="testing-platform"
        options={@platforms}
        selected={@issue.testing_platform}
        event="save_place"
        value_name="testing_platform"
        disabled={!@editable}
        role="group"
        aria-label="Platform"
      />
      <span
        :if={@locked}
        id="testing-device-text"
        title={@issue.testing_device}
        class="min-w-0 max-w-full text-[13px] text-slate-700 dark:text-slate-200 truncate"
      >
        {@issue.testing_device}
      </span>
      <label :if={!@locked} for="testing-device" class="sr-only">Device</label>
      <input
        :if={!@locked}
        id="testing-device"
        name="testing_device"
        type="text"
        value={@issue.testing_device}
        maxlength="200"
        phx-debounce="500"
        disabled={!@editable}
        placeholder="Device, such as Pixel 8 or iPhone 15"
        class="w-72 min-w-0 max-w-full rounded-md border-0 bg-white dark:bg-slate-900 px-2.5 py-1 text-[13px] text-slate-800 dark:text-slate-200 placeholder-slate-400 dark:placeholder-slate-500 ring-1 ring-inset ring-slate-300 dark:ring-slate-600 focus:ring-2 focus:ring-blue-500 focus:outline-none disabled:opacity-60"
      />
    </div>
    """
  end
end

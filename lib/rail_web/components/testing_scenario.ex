defmodule RailWeb.Components.TestingScenario do
  @moduledoc """
  One test scenario on the Testing page, marked Passed or Failed, with a note and pictures once it failed.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.TestingScenario

  attr :issue_id, :string, required: true
  attr :scenario, TestingScenario, required: true
  attr :number, :integer, required: true
  attr :editable, :boolean, required: true, doc: "in the queue and not being written"
  attr :upload_ref, :string, required: true, doc: "the page's one picture upload input, for Attach pictures"
  attr :uploading, :list, default: [], doc: "upload entries started on this scenario"
  attr :notes_rev, :integer, default: 0

  def testing_scenario(assigns) do
    assigns = assign(assigns, :failed, assigns.scenario.result == :failed)

    ~H"""
    <li
      id={"testing-scenario-#{@scenario.id}"}
      data-result={@scenario.result}
      class={["rounded-xl border px-3 py-2.5", row_class(@failed)]}
    >
      <div class="flex items-start gap-3">
        <span
          class={[
            "mt-0.5 h-6 w-6 shrink-0 rounded-full text-[11px] font-semibold flex items-center justify-center",
            mark_class(@scenario.result)
          ]}
          aria-hidden="true"
        >
          <.icon :if={@scenario.result == :passed} name="pi-check-bold" class="size-3" />
          <.icon :if={@failed} name="pi-x-bold" class="size-3" />
          <span :if={is_nil(@scenario.result)}>{@number}</span>
        </span>
        <div class="flex-1 min-w-0">
          <p class="text-[13.5px] leading-snug break-words text-slate-900 dark:text-slate-100">
            {@scenario.title}
          </p>
          <div :if={@scenario.source == :agent} class="mt-1.5">
            <span
              id={"testing-scenario-#{@scenario.id}-agent"}
              class="inline-flex items-center gap-1 whitespace-nowrap px-1.5 py-0.5 rounded text-[11px] font-semibold ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-slate-600 dark:text-slate-300"
            >
              <.icon name="pi-lightbulb" class="size-3" />From the issue
            </span>
          </div>
        </div>
        <div role="group" aria-label={"Result of scenario #{@number}"} class="flex shrink-0">
          <button
            :for={result <- TestingScenario.results()}
            type="button"
            id={"testing-scenario-#{@scenario.id}-#{result}"}
            phx-click="mark_scenario"
            phx-value-issue_id={@issue_id}
            phx-value-scenario_id={@scenario.id}
            phx-value-result={result}
            aria-pressed={to_string(@scenario.result == result)}
            disabled={!@editable}
            class={[
              "inline-flex items-center gap-1 px-2.5 py-1 text-xs font-semibold ring-1 ring-inset cursor-pointer first:rounded-l-md last:rounded-r-md -ml-px first:ml-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 disabled:opacity-60 disabled:cursor-default",
              result_class(result, @scenario.result == result)
            ]}
          >
            <.icon name={if result == :passed, do: "pi-check-bold", else: "pi-x-bold"} class="size-3" />{TestingScenario.result_label(
              result
            )}
          </button>
        </div>
        <button
          :if={@editable}
          type="button"
          id={"testing-scenario-#{@scenario.id}-remove"}
          phx-click="remove_scenario"
          phx-value-issue_id={@issue_id}
          phx-value-scenario_id={@scenario.id}
          aria-label={"Remove scenario #{@number}"}
          title="Remove scenario"
          class="h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-md text-slate-500 hover:bg-red-500/10 hover:text-red-500 dark:hover:text-red-400 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-trash" class="size-4" />
        </button>
      </div>

      <div
        :if={@failed and @editable}
        id={"testing-scenario-#{@scenario.id}-note"}
        class="mt-3 ml-9 rounded-xl bg-white dark:bg-slate-900 ring-1 ring-slate-300 dark:ring-slate-600 focus-within:ring-2 focus-within:ring-blue-500"
      >
        <div :if={@scenario.images != [] or @uploading != []} class="flex flex-wrap gap-2 px-3 pt-3">
          <.image_chip
            :for={{image, index} <- Enum.with_index(@scenario.images)}
            id={"testing-scenario-#{@scenario.id}-image-#{index}"}
            name={image.name}
            src={image.url}
            phx-click="remove_testing_image"
            phx-value-issue_id={@issue_id}
            phx-value-scenario_id={@scenario.id}
            phx-value-url={image.url}
          />
          <.image_chip
            :for={entry <- @uploading}
            id={"testing-upload-#{entry.ref}"}
            name={entry.client_name}
            entry={entry}
            busy
            removable={false}
          />
        </div>
        <label for={"testing-note-#{@scenario.id}"} class="sr-only">What went wrong</label>
        <textarea
          id={"testing-note-#{@scenario.id}"}
          name={"notes[#{@scenario.id}]"}
          rows="2"
          maxlength="10000"
          phx-debounce="500"
          phx-focus="image_target"
          phx-value-scenario_id={@scenario.id}
          phx-blur="notes_blurred"
          phx-hook="ImagePaste"
          data-upload-name="testing_images"
          data-rev={@notes_rev}
          placeholder="What went wrong... Paste pictures here."
          class="block w-full resize-y rounded-xl border-0 bg-transparent px-4 py-3 text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-200 placeholder-slate-400 dark:placeholder-slate-500 focus:outline-none focus:ring-0 break-words"
        >{@scenario.note}</textarea>
        <div class="flex items-center gap-3 px-3 pb-2">
          <span class="text-xs text-slate-500 dark:text-slate-400">Saves as you type</span>
          <label
            for={@upload_ref}
            id={"testing-scenario-#{@scenario.id}-attach"}
            phx-click="image_target"
            phx-value-scenario_id={@scenario.id}
            class="ml-auto inline-flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-semibold text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
          >
            <.icon name="pi-image" class="size-4" />Attach pictures
          </label>
        </div>
      </div>

      <div
        :if={@failed and !@editable and (@scenario.note not in [nil, ""] or @scenario.images != [])}
        id={"testing-scenario-#{@scenario.id}-note"}
        class="mt-3 ml-9 space-y-2"
      >
        <p
          :if={@scenario.note not in [nil, ""]}
          class="text-[13px] leading-relaxed whitespace-pre-wrap break-words text-slate-700 dark:text-slate-300"
          phx-no-format
        >{@scenario.note}</p>
        <div :if={@scenario.images != []} class="flex flex-wrap gap-2">
          <.image_chip
            :for={{image, index} <- Enum.with_index(@scenario.images)}
            id={"testing-scenario-#{@scenario.id}-image-#{index}"}
            name={image.name}
            src={image.url}
            removable={false}
          />
        </div>
      </div>
    </li>
    """
  end

  defp row_class(true), do: "border-red-500/60 bg-red-500/5"
  defp row_class(false), do: "border-slate-200 dark:border-slate-700/80 bg-white dark:bg-slate-900"

  defp mark_class(:passed), do: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-300"
  defp mark_class(:failed), do: "bg-red-500/15 text-red-600 dark:text-red-300"

  defp mark_class(nil),
    do:
      "bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-slate-200 dark:ring-slate-700"

  defp result_class(:passed, true), do: "bg-emerald-600 text-white ring-emerald-600 relative z-10"
  defp result_class(:failed, true), do: "bg-red-600 text-white ring-red-600 relative z-10"

  defp result_class(_result, false),
    do:
      "bg-white dark:bg-slate-800 text-slate-600 dark:text-slate-300 ring-slate-300 dark:ring-slate-600 hover:bg-slate-50 dark:hover:bg-slate-700"
end

defmodule RailWeb.Components.PlanDiagram do
  @moduledoc """
  One diagram from an implementation plan, drawn in the browser by the `PlanDiagram`
  hook. The server only ever sends the Mermaid source, as escaped text, and the ids of
  the nodes the hook puts a + on. Source view is the source line by line, each a line
  that takes a comment, and a node's comments sit under the figure naming the node.
  """
  use RailWeb, :html

  @titles %{change: "Change diagram", call_flow: "Call flow"}
  @icons %{change: "pi-flow-arrow", call_flow: "pi-arrows-left-right"}

  attr :diagram, :map, required: true, doc: "a diagram from `build_plan_sheet/1`"
  attr :view, :atom, required: true, values: [:diagram, :source]
  attr :event, :string, required: true
  attr :target, :any, default: nil
  attr :placed, :map, default: %{}, doc: "the reader's comments on each line, by its key"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under"
  attr :offered, :boolean, default: false, doc: "the reader can comment now"

  def plan_diagram(%{diagram: %{kind: kind, source: source}} = assigns) do
    nodes =
      for node <- assigns.diagram.nodes,
          do: %{id: node.text, key: node.key, label: node.label, commented: Map.has_key?(assigns.placed, node.key)}

    # Keyed on the source, so a rewritten plan mounts a fresh hook that draws it.
    assigns =
      assigns
      |> assign(:id, "plan-diagram-#{kind}-#{:erlang.phash2(source)}")
      |> assign(:title, Map.fetch!(@titles, kind))
      |> assign(:icon, Map.fetch!(@icons, kind))
      |> assign(:nodes, Jason.encode!(nodes))

    ~H"""
    <figure
      id={@id}
      phx-hook="PlanDiagram"
      data-qa="plan_diagram"
      data-nodes={@nodes}
      data-offered={to_string(@offered)}
      class="not-prose group/diagram m-0 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 overflow-hidden [&:fullscreen]:overflow-auto"
    >
      <figcaption class="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2.5 border-b border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40">
        <.icon name={@icon} class="size-5 text-slate-400" />
        <span class="text-sm font-semibold text-slate-900 dark:text-slate-100">{@title}</span>
        <span class="min-w-0 text-xs text-slate-500 dark:text-slate-400">{@diagram.caption}</span>

        <div class="ml-auto flex items-center gap-2">
          <span class="hidden group-data-[drawn=error]/diagram:inline text-xs text-slate-500 dark:text-slate-400">
            Source only
          </span>

          <.segmented_control
            id={"#{@id}-view"}
            options={[{"#{@diagram.kind}:diagram", "Diagram"}, {"#{@diagram.kind}:source", "Source"}]}
            selected={"#{@diagram.kind}:#{@view}"}
            event={@event}
            target={@target}
            value_name="view"
            class="group-data-[drawn=error]/diagram:hidden"
          />

          <button
            type="button"
            data-diagram-fullscreen
            title="Full screen"
            aria-label="Full screen"
            class="hidden size-8 place-items-center rounded-lg border border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer group-data-[drawn=error]/diagram:hidden!"
          >
            <.icon name="pi-arrows-out" class="size-4" />
          </button>
        </div>
      </figcaption>

      <div class="hidden group-data-[drawn=error]/diagram:flex items-start gap-2.5 px-4 py-3 border-b border-slate-200 dark:border-slate-700 border-l-2 border-l-amber-400 bg-amber-50 dark:bg-slate-800/40">
        <.icon name="pi-warning" class="size-5 text-amber-500 dark:text-amber-300" />
        <div class="min-w-0">
          <p class="text-sm font-semibold text-slate-900 dark:text-slate-100">
            This diagram could not be drawn, so it is shown as written.
          </p>
          <p
            id={"#{@id}-error"}
            phx-update="ignore"
            data-diagram-error
            class="mt-0.5 font-mono text-xs text-slate-500 dark:text-slate-400"
          >
          </p>
        </div>
      </div>

      <div class={[
        "relative",
        @view == :source && "hidden",
        "group-data-[drawn=error]/diagram:hidden"
      ]}>
        <div
          id={"#{@id}-canvas"}
          phx-update="ignore"
          data-diagram-canvas
          class="px-6 py-4 [&_svg]:block [&_svg]:mx-auto [:fullscreen_&_svg]:max-w-none!"
        >
        </div>
        <div
          id={"#{@id}-nodes"}
          phx-update="ignore"
          data-diagram-nodes
          class="absolute inset-0 pointer-events-none"
        >
        </div>
      </div>

      <pre data-diagram-source class="hidden">{@diagram.source}</pre>

      <div
        data-qa="plan_diagram_source"
        class={[
          "py-2 bg-slate-50 dark:bg-slate-950",
          @view == :diagram && "hidden group-data-[drawn=error]/diagram:block"
        ]}
      >
        <.commentable_line
          :for={line <- @diagram.source_lines}
          line={line}
          layout={:code}
          framed={false}
          doc={:plan}
          placed={@placed}
          draft={@draft}
          offered={@offered}
          target={@target}
        />
      </div>

      <.commentable_line
        :for={node <- @diagram.nodes}
        line={node}
        layout={:node}
        doc={:plan}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
      />
    </figure>
    """
  end
end

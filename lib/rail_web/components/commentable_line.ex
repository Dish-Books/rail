defmodule RailWeb.Components.CommentableLine do
  @moduledoc """
  One line of the ticket or the plan with the + that comments on it, as a diff line has, then its comments in tray
  order and the box being written. Where the + and the comments sit depends on the line: in the gutter for text, over
  the number for code, inside the card for a summary line, and in a full-width row under a table row.
  """
  use RailWeb, :html

  attr :line, :map, default: nil, doc: "a line from `build_document_blocks/1` or `build_plan_sheet/1`"
  attr :doc, :atom, required: true, values: [:ticket, :plan]
  attr :layout, :atom, default: :text, values: [:text, :code, :table_row, :summary, :node, :values]
  attr :placed, :map, required: true, doc: "each line's comments with their tray numbers, by its key"
  attr :draft, :map, default: nil, doc: "the line the comment box is open under, with what is typed so far"
  attr :offered, :boolean, required: true, doc: "the reader can comment now"
  attr :framed, :boolean, default: true, doc: "a code line draws the block it is in"
  attr :named, :boolean, default: false, doc: "its comments name the line, being drawn away from it"
  attr :class, :any, default: nil
  attr :target, :any, required: true

  slot :inner_block, doc: "what the line shows, in place of what its kind draws"

  slot :value, doc: "one value of a row of values, each a line of its own" do
    attr :line, :map, required: true
  end

  def commentable_line(%{layout: :values} = assigns) do
    lines = Enum.map(assigns.value, & &1.line)

    assigns =
      assigns
      |> assign(:comments, lines |> Enum.flat_map(&Map.get(assigns.placed, &1.key, [])) |> Enum.sort_by(&elem(&1, 1)))
      |> assign(:open, open(assigns.draft, assigns.doc, lines))

    ~H"""
    <div data-qa="commentable_line" class={@class}>
      <div class="relative -mx-2 flex flex-wrap items-center gap-1">
        <span
          :for={value <- @value}
          id={"line-#{@doc}-#{value.line.key}"}
          data-qa="commentable_value"
          class={[
            "group/line inline-flex items-center gap-1.5 h-7 px-2 rounded-md text-[13px] text-slate-600 dark:text-slate-300",
            @offered && "line-comment-value"
          ]}
        >
          <.add :if={@offered} line={value.line} doc={@doc} target={@target} class="-left-6 top-1" />
          {render_slot(value)}
        </span>
      </div>
      <.under
        comments={@comments}
        open={@open}
        draft={@draft}
        named
        target={@target}
        class="mt-1 mb-2"
      />
    </div>
    """
  end

  def commentable_line(%{layout: :node} = assigns) do
    assigns = assign_under(assigns)

    ~H"""
    <.under
      comments={@comments}
      open={@open}
      draft={@draft}
      named
      target={@target}
      class={[
        "px-4 py-2.5 bg-slate-50 dark:bg-slate-800/40 border-t border-slate-200 dark:border-slate-700",
        @class
      ]}
    />
    """
  end

  def commentable_line(%{layout: :code} = assigns) do
    assigns = assign_under(assigns)

    ~H"""
    <div
      data-qa="commentable_line"
      data-kind={@line.kind}
      class={[
        @framed && "bg-slate-50 dark:bg-slate-950 border-x border-slate-200 dark:border-slate-800",
        @framed && @line.first? && "mt-2 pt-1.5 border-t rounded-t-lg",
        @framed && @line.last? && "mb-2 pb-1.5 border-b rounded-b-lg",
        @class
      ]}
    >
      <div
        id={"line-#{@doc}-#{@line.key}"}
        class={[
          "group/line relative flex font-mono text-[12.5px] leading-[22px]",
          @offered && "hover:bg-slate-200/60 dark:hover:bg-slate-800"
        ]}
      >
        <.add
          :if={@offered and @line.text != ""}
          line={@line}
          doc={@doc}
          target={@target}
          class="left-1 top-px"
        />
        <span
          data-qa="line_number"
          class={[
            "w-10 shrink-0 pr-3 text-right select-none tabular-nums",
            @comments == [] && "text-slate-400 dark:text-slate-500",
            @comments != [] && "font-bold text-amber-700 dark:text-amber-300"
          ]}
        >
          {@line.number}
        </span>
        <span
          phx-no-format
          class="min-w-0 pl-2 pr-4 whitespace-pre-wrap wrap-anywhere text-slate-800 dark:text-slate-200"
        >{@line.text}</span>
      </div>
      <.under
        comments={@comments}
        open={@open}
        draft={@draft}
        named={@named}
        target={@target}
        class="py-1.5 pr-4 pl-[52px] bg-slate-50 dark:bg-slate-800/40 border-y border-slate-200 dark:border-slate-700 font-sans"
      />
    </div>
    """
  end

  def commentable_line(%{layout: :table_row} = assigns) do
    assigns = assign_under(assigns)

    ~H"""
    <div
      data-qa="commentable_line"
      data-kind={@line.kind}
      class={[
        "border-x border-slate-200 dark:border-slate-800",
        @line.first? && "mt-2 rounded-t-lg border-t",
        not @line.first? && "border-t",
        @line.last? && "mb-2 rounded-b-lg border-b",
        @class
      ]}
    >
      <div
        id={"line-#{@doc}-#{@line.key}"}
        style={"grid-template-columns: repeat(#{max(@line.columns, 1)}, minmax(0, 1fr))"}
        class={[
          "group/line relative grid text-[14px] text-slate-700 dark:text-slate-300",
          @line.header? && "font-semibold text-[12px] text-slate-500 dark:text-slate-400",
          @offered && "hover:bg-slate-100 dark:hover:bg-slate-800/60"
        ]}
      >
        <.add :if={@offered} line={@line} doc={@doc} target={@target} class="-left-8 top-1.5" />
        <div
          :for={cell <- @line.cells}
          class="min-w-0 px-3 py-1.5 wrap-anywhere prose prose-slate dark:prose-invert max-w-none text-[inherit] [&_p]:my-0"
        >
          {raw(cell)}
        </div>
      </div>
      <.under
        comments={@comments}
        open={@open}
        draft={@draft}
        named={@named}
        target={@target}
        class="px-3 py-1.5 bg-slate-50 dark:bg-slate-800/40 border-t border-slate-200 dark:border-slate-700"
      />
    </div>
    """
  end

  def commentable_line(%{layout: :summary} = assigns) do
    assigns = assign_under(assigns)

    ~H"""
    <div data-qa="commentable_line" data-kind={@line.kind} class={@class}>
      <div
        id={"line-#{@doc}-#{@line.key}"}
        class={[
          "group/line relative flex items-start gap-2 -mx-1.5 px-1.5 py-0.5 rounded",
          @offered && "hover:bg-slate-200/70 dark:hover:bg-slate-700/50"
        ]}
      >
        <.add :if={@offered} line={@line} doc={@doc} target={@target} class="-left-[26px] top-0.5" />
        {render_slot(@inner_block)}
      </div>
      <.under
        comments={@comments}
        open={@open}
        draft={@draft}
        named={@named}
        target={@target}
        class="py-1"
      />
    </div>
    """
  end

  def commentable_line(assigns) do
    assigns = assign_under(assigns)

    ~H"""
    <div
      data-qa="commentable_line"
      data-kind={@line.kind}
      style={@line.depth > 0 && "margin-left: #{@line.depth * 22}px"}
      class={[@line.kind == :heading && "mt-5 first:mt-0", @class]}
    >
      <div
        id={"line-#{@doc}-#{@line.key}"}
        class={[
          "group/line relative rounded-md -mx-2 px-2 py-0.5",
          @offered && "hover:bg-slate-100 dark:hover:bg-slate-800/50"
        ]}
      >
        <.add :if={@offered} line={@line} doc={@doc} target={@target} class="-left-6 top-1" />
        {render_slot(@inner_block)}
        <.content :if={@inner_block == []} line={@line} />
      </div>
      <.under
        comments={@comments}
        open={@open}
        draft={@draft}
        named={@named}
        target={@target}
        class="ml-4 mt-1 mb-2"
      />
    </div>
    """
  end

  attr :line, :map, required: true
  attr :doc, :atom, required: true
  attr :target, :any, required: true
  attr :class, :string, required: true

  defp add(assigns) do
    ~H"""
    <button
      type="button"
      data-qa="line_comment_add"
      aria-label={"Comment on #{@line.label}"}
      phx-click="open_document_comment"
      phx-value-doc={@doc}
      phx-value-key={@line.key}
      phx-target={@target}
      class={["line-comment-add", @class]}
    >
      +
    </button>
    """
  end

  attr :comments, :list, required: true
  attr :open, :boolean, required: true
  attr :draft, :map, default: nil
  attr :named, :boolean, default: false
  attr :target, :any, required: true
  attr :class, :any, required: true

  defp under(assigns) do
    ~H"""
    <div :if={@comments != [] or @open} data-qa="line_comments" class={["space-y-1.5", @class]}>
      <.document_comment
        :for={{comment, number} <- @comments}
        comment={comment}
        number={number}
        named={@named}
        target={@target}
      />
      <.comment_box
        :if={@open}
        id={"document-comment-form-#{@draft.key}"}
        body_id={"document-comment-body-#{@draft.key}"}
        qa="document_comment"
        label={@draft.label}
        body={@draft.body}
        submit="save_plan_comment"
        change="change_plan_comment"
        cancel="cancel_plan_comment"
        target={@target}
      />
    </div>
    """
  end

  attr :line, :map, required: true

  # What a line of a document draws when the page gives it nothing else to show.
  defp content(%{line: %{kind: :list_item}} = assigns) do
    ~H"""
    <div class="flex gap-2.5">
      <span
        :if={@line.marker == :bullet}
        class={[
          "mt-[9px] size-1.5 shrink-0 rounded-full",
          @line.depth == 0 && "bg-slate-400 dark:bg-slate-500",
          @line.depth > 0 && "border border-slate-400 dark:border-slate-500"
        ]}
      />
      <span
        :if={match?({:ordered, _number}, @line.marker)}
        class="shrink-0 text-[15px] leading-relaxed tabular-nums text-slate-500 dark:text-slate-400"
      >
        {elem(@line.marker, 1)}.
      </span>
      <.icon
        :if={match?({:task, _checked}, @line.marker)}
        name={if elem(@line.marker, 1), do: "pi-check-square", else: "pi-square"}
        class="mt-1 size-4 shrink-0 text-slate-400 dark:text-slate-500"
      />
      <.prose html={@line.html} />
    </div>
    """
  end

  defp content(%{line: %{kind: :blockquote}} = assigns) do
    ~H"""
    <div class="pl-3 border-l-2 border-slate-300 dark:border-slate-600 [&_*]:text-slate-500 dark:[&_*]:text-slate-400">
      <.prose html={@line.html} />
    </div>
    """
  end

  defp content(assigns) do
    ~H"""
    <.prose html={@line.html} />
    """
  end

  attr :html, :string, required: true

  defp prose(assigns) do
    ~H"""
    <div class="min-w-0 prose prose-slate dark:prose-invert max-w-none text-[15px] leading-relaxed wrap-anywhere [&>*]:my-0 prose-headings:my-0 prose-headings:text-[17px] prose-headings:font-semibold">
      {raw(@html)}
    </div>
    """
  end

  defp assign_under(assigns) do
    assigns
    |> assign(:comments, Map.get(assigns.placed, assigns.line && assigns.line.key, []))
    |> assign(:open, open(assigns.draft, assigns.doc, [assigns.line]))
  end

  defp open(%{doc: doc, key: key}, doc, lines), do: Enum.any?(lines, &(&1.key == key))
  defp open(_draft, _doc, _lines), do: false
end

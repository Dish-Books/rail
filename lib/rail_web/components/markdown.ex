defmodule RailWeb.Components.Markdown do
  @moduledoc """
  Component for rendering sanitized, safe markdown prose.
  """
  use RailWeb, :html

  attr :content, :string, default: ""
  attr :class, :string, default: nil

  def markdown(assigns) do
    content = assigns.content || ""
    html = render_markdown(content)
    assigns = assign(assigns, :rendered_html, html)

    ~H"""
    <div data-qa="markdown-body" class={["prose max-w-none text-sm leading-relaxed", @class]}>
      {Phoenix.HTML.raw(@rendered_html)}
    </div>
    """
  end

  @doc """
  Transforms a markdown string into sanitized HTML.
  """
  def to_html(nil), do: ""
  def to_html(""), do: ""
  def to_html(content) when is_binary(content), do: render_markdown(content)

  defp render_markdown(content) do
    lines = content |> String.replace("\r\n", "\n") |> String.split("\n")
    blocks = parse_blocks(lines, [])
    Enum.map_join(blocks, "\n", &render_block/1)
  end

  defp parse_blocks([], acc), do: Enum.reverse(acc)

  defp parse_blocks([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        parse_blocks(rest, acc)

      String.starts_with?(trimmed, "```") ->
        {code_lines, remaining} = collect_code_block(rest, [])
        parse_blocks(remaining, [{:code_block, Enum.join(code_lines, "\n")} | acc])

      String.starts_with?(trimmed, "#") ->
        parse_blocks(rest, [parse_heading(trimmed) | acc])

      String.starts_with?(trimmed, ">") ->
        {quote_lines, remaining} = collect_blockquote([line | rest], [])
        parse_blocks(remaining, [{:blockquote, Enum.join(quote_lines, " ")} | acc])

      list_item?(trimmed) ->
        {list_type, items, remaining} = collect_list([line | rest])
        parse_blocks(remaining, [{list_type, items} | acc])

      true ->
        {para_lines, remaining} = collect_paragraph([line | rest], [])
        parse_blocks(remaining, [{:p, Enum.join(para_lines, " ")} | acc])
    end
  end

  defp collect_code_block([], acc), do: {Enum.reverse(acc), []}

  defp collect_code_block([line | rest], acc) do
    if String.starts_with?(String.trim(line), "```") do
      {Enum.reverse(acc), rest}
    else
      collect_code_block(rest, [line | acc])
    end
  end

  defp parse_heading(line) do
    cond do
      String.starts_with?(line, "#### ") -> {:h4, String.replace_prefix(line, "#### ", "")}
      String.starts_with?(line, "### ") -> {:h3, String.replace_prefix(line, "### ", "")}
      String.starts_with?(line, "## ") -> {:h2, String.replace_prefix(line, "## ", "")}
      String.starts_with?(line, "# ") -> {:h1, String.replace_prefix(line, "# ", "")}
      true -> {:p, line}
    end
  end

  defp collect_blockquote([], acc), do: {Enum.reverse(acc), []}

  defp collect_blockquote([line | rest], acc) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, ">") do
      cleaned = trimmed |> String.replace_prefix(">", "") |> String.trim()
      collect_blockquote(rest, [cleaned | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp list_item?(line) do
    unordered_item?(line) or ordered_item?(line)
  end

  defp unordered_item?(line) do
    String.starts_with?(line, "- ") or String.starts_with?(line, "* ")
  end

  defp ordered_item?(line) do
    Regex.match?(~r/^\d+\.\s+/, line)
  end

  defp collect_list([first_line | _rest] = lines) do
    trimmed = String.trim(first_line)
    list_type = if ordered_item?(trimmed), do: :ol, else: :ul
    do_collect_list(lines, list_type, [])
  end

  defp do_collect_list([], list_type, acc), do: {list_type, Enum.reverse(acc), []}

  defp do_collect_list([line | rest] = current_lines, list_type, acc) do
    trimmed = String.trim(line)

    is_current_type =
      if list_type == :ol do
        ordered_item?(trimmed)
      else
        unordered_item?(trimmed)
      end

    if is_current_type do
      item_text =
        if list_type == :ol do
          Regex.replace(~r/^\d+\.\s+/, trimmed, "")
        else
          String.slice(trimmed, 2..-1//1)
        end

      do_collect_list(rest, list_type, [item_text | acc])
    else
      {list_type, Enum.reverse(acc), current_lines}
    end
  end

  defp collect_paragraph([], acc), do: {Enum.reverse(acc), []}

  defp collect_paragraph([line | rest] = current_lines, acc) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "```") or
         String.starts_with?(trimmed, ">") or list_item?(trimmed) do
      {Enum.reverse(acc), current_lines}
    else
      collect_paragraph(rest, [trimmed | acc])
    end
  end

  defp render_block({:h1, text}),
    do: "<h1 class=\"text-xl font-bold my-2 text-[var(--color-on-surface)]\">#{inline_format(text)}</h1>"

  defp render_block({:h2, text}),
    do: "<h2 class=\"text-lg font-bold my-2 text-[var(--color-on-surface)]\">#{inline_format(text)}</h2>"

  defp render_block({:h3, text}),
    do: "<h3 class=\"text-base font-semibold my-1.5 text-[var(--color-on-surface)]\">#{inline_format(text)}</h3>"

  defp render_block({:h4, text}),
    do: "<h4 class=\"text-sm font-semibold my-1 text-[var(--color-on-surface)]\">#{inline_format(text)}</h4>"

  defp render_block({:p, text}),
    do: "<p class=\"my-1.5 leading-relaxed text-[var(--color-on-surface)]\">#{inline_format(text)}</p>"

  defp render_block({:blockquote, text}),
    do:
      "<blockquote class=\"border-l-4 border-[var(--color-outline-variant)] pl-3 my-2 italic text-[var(--color-outline)]\">#{inline_format(text)}</blockquote>"

  defp render_block({:code_block, code}),
    do:
      "<pre class=\"p-3 my-2 rounded-lg bg-[var(--color-surface-container-highest)] font-mono text-xs overflow-x-auto text-[var(--color-on-surface)]\"><code>#{escape_html(code)}</code></pre>"

  defp render_block({:ul, items}) do
    rendered_items =
      Enum.map_join(items, "", fn item ->
        "<li class=\"my-0.5\">#{inline_format(item)}</li>"
      end)

    "<ul class=\"list-disc list-inside space-y-0.5 my-2 text-[var(--color-on-surface)]\">#{rendered_items}</ul>"
  end

  defp render_block({:ol, items}) do
    rendered_items =
      Enum.map_join(items, "", fn item ->
        "<li class=\"my-0.5\">#{inline_format(item)}</li>"
      end)

    "<ol class=\"list-decimal list-inside space-y-0.5 my-2 text-[var(--color-on-surface)]\">#{rendered_items}</ol>"
  end

  defp inline_format(text) do
    escaped = escape_html(text)

    {text_without_code, code_map} =
      ~r/`([^`]+)`/
      |> Regex.scan(escaped)
      |> Enum.with_index()
      |> Enum.reduce({escaped, %{}}, fn {[full, code], idx}, {acc, map} ->
        placeholder = "##CODE#{idx}##"
        replaced = String.replace(acc, full, placeholder, global: false)

        code_html =
          "<code class=\"px-1 py-0.5 rounded bg-[var(--color-surface-container-highest)] font-mono text-xs\">#{code}</code>"

        {replaced, Map.put(map, placeholder, code_html)}
      end)

    {text_without_links, link_map} =
      ~r/\[([^\]]+)\]\(([^)]+)\)/
      |> Regex.scan(text_without_code)
      |> Enum.with_index()
      |> Enum.reduce({text_without_code, %{}}, fn {[full, label, url], idx}, {acc, map} ->
        placeholder = "##LINK#{idx}##"
        replaced = String.replace(acc, full, placeholder, global: false)

        link_html =
          "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"text-[var(--color-primary)] hover:underline\">#{label}</a>"

        {replaced, Map.put(map, placeholder, link_html)}
      end)

    formatted =
      text_without_links
      |> format_bold()
      |> format_italic()

    with_links =
      Enum.reduce(link_map, formatted, fn {placeholder, html}, acc ->
        String.replace(acc, placeholder, html)
      end)

    Enum.reduce(code_map, with_links, fn {placeholder, html}, acc ->
      String.replace(acc, placeholder, html)
    end)
  end

  defp escape_html(text) do
    Plug.HTML.html_escape(text)
  end

  defp format_bold(text) do
    Regex.replace(~r/\*\*([^*]+)\*\*/, text, fn _full, content ->
      "<strong>#{content}</strong>"
    end)
  end

  defp format_italic(text) do
    step1 = Regex.replace(~r/_([^_]+)_/, text, fn _full, content -> "<em>#{content}</em>" end)
    Regex.replace(~r/(?<!\*)\*([^*]+)\*(?!\*)/, step1, fn _full, content -> "<em>#{content}</em>" end)
  end
end

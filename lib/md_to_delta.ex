defmodule MdToDelta do
  @moduledoc """
  Documentation for MdToDelta
  """

  @doc """
  Parses a markdown string into an array of delta operations
  ## Example

      iex> MdToDelta.parse("# Hello\\nWorld")
      [
        %{"insert" => "Hello"},
        %{"attributes" => %{"header" => 1}, "insert" => "\\n"},
        %{"insert" => "\\n"},
        %{"insert" => "World"},
        %{"insert" => "\\n"}
      ]
  """
  def parse(binary) do
    {:ok, ast_nodes, _messages} = EarmarkParser.as_ast(binary)

    lookahead_list =
      ast_nodes
      |> Enum.drop(1)
      |> Enum.concat([nil])

    ast_nodes
    |> Enum.zip(lookahead_list)
    |> Enum.map(&visit_block(&1, []))
    |> List.flatten()
    |> Enum.map(&convert_to_delta_ops/1)
  end

  @layout_blocks ~w(ul ol table)
  @text_blocks ~w(p pre h1 h2 h3 h4 h5 h6)

  defp maybe_add_newline(
         {curr_tag, _attrs1, _children1, _meta1},
         {next_tag, _attrs2, _children2, _meta2}
       )
       when curr_tag in @layout_blocks and next_tag in @text_blocks do
    [{"\n", [], []}, {"\n", [], []}]
  end

  @blocks ~w(p pre h1 h2 h3 h4 h5 h6 ul ol table)

  defp maybe_add_newline(
         {curr_tag, _attrs1, _children1, _meta1},
         {next_tag, _attrs2, _children2, _meta2}
       )
       when curr_tag in @blocks and next_tag in @blocks do
    [{"\n", [], []}]
  end

  defp maybe_add_newline(_curr, _next) do
    []
  end

  defp visit_block(
         {
           {"hr", [{"class", "thin"}], _children, _meta},
           _next
         },
         acc
       ) do
    acc ++ [{%{"divider" => true}, [], []}, {"\n", [], []}]
  end

  @blocks_without_newline ~w(ol ul pre table)

  defp visit_block(
         {
           {tag, _attributes, children, _meta} = ast,
           next
         },
         acc
       )
       when tag not in @blocks_without_newline do
    attributes = ast_to_attribute(ast)
    parents = [tag]

    acc ++
      List.flatten(Enum.map(children, &visit_child(&1, parents, attributes, acc))) ++
      [{"\n", parents, attributes}] ++ maybe_add_newline(ast, next)
  end

  defp visit_block(
         {
           {tag, _attributes, children, _meta} = ast,
           next
         },
         acc
       ) do
    attributes = ast_to_attribute(ast)

    acc ++
      List.flatten(Enum.map(children, &visit_child(&1, [tag], attributes, acc))) ++
      maybe_add_newline(ast, next)
  end

  defp visit_child(child, [_inline_parent, "li" | _] = parents, parent_attributes, acc)
       when is_binary(child) do
    nesting_count = Enum.count(parents, &(&1 in ["ol", "ul"]))

    parent_attributes =
      if nesting_count > 1 do
        Keyword.put(parent_attributes, :indent, nesting_count - 1)
      else
        parent_attributes
      end

    acc ++ [{child, parents, parent_attributes}]
  end

  defp visit_child(child, ["li" | _] = parents, parent_attributes, acc)
       when is_binary(child) do
    nesting_count = Enum.count(parents, &(&1 in ["ol", "ul"]))

    parent_attributes =
      if nesting_count > 1 do
        Keyword.put(parent_attributes, :indent, nesting_count - 1)
      else
        parent_attributes
      end

    acc ++ [{child, parents, parent_attributes}]
  end

  defp visit_child(child, ["code" | _] = parents, parent_attributes, acc)
       when is_binary(child) and child != "\n" do
    acc ++ [{child, parents, parent_attributes}, {"\n", parents, parent_attributes}]
  end

  defp visit_child(child, parents, parent_attributes, acc) when is_binary(child) do
    acc ++ [{child, parents, parent_attributes}]
  end

  defp visit_child(
         {"img", [{"src", src}, {"alt", _alt}], _, _} = child,
         parents,
         _parent_attributes,
         acc
       ) do
    attributes = ast_to_attribute(child)

    acc ++ [{%{"image" => src}, parents, attributes}]
  end

  defp visit_child({"thead", _, children, _}, parents, parent_attributes, acc) do
    parent_attributes = Keyword.put(parent_attributes, :table, 1)

    acc ++
      List.flatten(
        Enum.map(children, &visit_child(&1, ["thead"] ++ parents, parent_attributes, acc))
      )
  end

  defp visit_child({"tbody", _, children, _}, parents, parent_attributes, acc) do
    children = Enum.with_index(children)

    acc ++
      List.flatten(
        Enum.map(
          children,
          &visit_child(
            elem(&1, 0),
            ["tbody"] ++ parents,
            Keyword.put(parent_attributes, :table, elem(&1, 1) + 2),
            acc
          )
        )
      )
  end

  defp visit_child(
         {cell_type, _attributes, children, _meta} = ast,
         parents,
         parent_attributes,
         acc
       )
       when cell_type in ["th", "td"] do
    attributes = ast_to_attribute(ast)
    parent_attributes = Keyword.merge(parent_attributes, attributes)
    parents = [cell_type] ++ parents

    acc ++
      List.flatten(Enum.map(children, &visit_child(&1, parents, parent_attributes, acc))) ++
      [{"\n", parents, Keyword.take(parent_attributes, [:table, :align])}]
  end

  defp visit_child(
         {"code", _attributes, [code_block_text], _meta} = ast,
         ["pre" | _] = parents,
         _parent_attributes,
         acc
       ) do
    attributes = ast_to_attribute(ast)

    lines =
      code_block_text
      |> String.split("\n")
      |> Enum.map(fn
        "" -> "\n"
        text -> text
      end)

    acc ++
      List.flatten(Enum.map(lines, &visit_child(&1, ["code"] ++ parents, attributes, acc)))
  end

  defp visit_child(
         {"code", _attributes, [inline_code_text], _meta} = ast,
         parents,
         parent_attributes,
         acc
       ) do
    attributes = ast_to_attribute(ast)
    parent_attributes = Keyword.merge(parent_attributes, attributes)

    acc ++ [{inline_code_text, parents, parent_attributes}]
  end

  defp visit_child({"li", _attributes, [child], _meta}, parents, parent_attributes, acc) do
    nesting_count = Enum.count(parents, &(&1 in ["ol", "ul"]))

    parent_attributes =
      if nesting_count > 1 do
        Keyword.put(parent_attributes, :indent, nesting_count - 1)
      else
        parent_attributes
      end

    parents = ["li"] ++ parents

    acc ++
      List.flatten(visit_child(child, ["li"] ++ parents, parent_attributes, acc)) ++
      [{"\n", parents, parent_attributes}]
  end

  defp visit_child({"li", _attributes, children, _meta}, parents, parent_attributes, acc) do
    nesting_count = Enum.count(parents, &(&1 in ["ol", "ul"]))

    parent_attributes =
      if nesting_count > 1 do
        Keyword.put(parent_attributes, :indent, nesting_count - 1)
      else
        parent_attributes
      end

    parents = ["li"] ++ parents

    has_nested_blocks =
      Enum.any?(children, fn
        {tag, _, _, _} -> tag in @blocks
        _ -> false
      end)

    if has_nested_blocks do
      acc ++
        List.flatten(
          children
          |> Enum.map(&visit_child(&1, parents, parent_attributes, acc))
          |> Enum.intersperse({"\n", parents, parent_attributes})
        )
    else
      acc ++
        List.flatten(
          Enum.map(children, &visit_child(&1, parents, parent_attributes, acc)) ++
            [{"\n", parents, parent_attributes}]
        )
    end
  end

  defp visit_child({tag, _atrributes, children, _meta} = ast, parents, parent_attributes, acc) do
    attributes = ast_to_attribute(ast)
    parent_attributes = Keyword.merge(parent_attributes, attributes)

    acc ++
      List.flatten(Enum.map(children, &visit_child(&1, [tag] ++ parents, parent_attributes, acc)))
  end

  defp convert_to_delta_ops({text, _parents, []}) when text in ["\n", %{divider: true}] do
    %{"insert" => text}
  end

  @inline_attributes ~w(bold italic link code strike alt)a

  defp convert_to_delta_ops({"\n" = text, _parents, attributes}) do
    attributes = Enum.reject(attributes, &(elem(&1, 0) in @inline_attributes))

    %{
      "insert" => text,
      "attributes" =>
        Map.new(
          attributes,
          fn {k, v} -> {k |> to_string() |> String.replace("_", "-"), v} end
        )
    }
  end

  defp convert_to_delta_ops({text, _parents, attributes}) do
    base = %{"insert" => text}
    attributes = Enum.filter(attributes, &(elem(&1, 0) in @inline_attributes))

    if attributes != [] do
      Map.merge(base, %{
        "attributes" =>
          Map.new(
            attributes,
            fn {k, v} -> {k |> to_string() |> String.replace("_", "-"), v} end
          )
      })
    else
      base
    end
  end

  # credo:disable-for-next-line
  defp ast_to_attribute(node) do
    case node do
      {"hr", _, _, _} -> []
      {"h" <> num, _, _, _} -> [header: String.to_integer(num)]
      {"strong", _, _, _} -> [bold: true]
      {"em", _, _, _} -> [italic: true]
      {"del", _, _, _} -> [strike: true]
      {"code", [{"class", "inline"}], _, _} -> [code: true]
      {"code", _, _, _} -> [code_block: true]
      {"blockquote", _, _, _} -> [blockquote: true]
      {"a", [{"href", link}], _, _} -> [link: link]
      {"ul", _, _, _} -> [list: "bullet"]
      {"ol", _, _, _} -> [list: "ordered"]
      {"th", [{"style", "text-align: left;"}], _, _} -> []
      {"th", [{"style", "text-align: center;"}], _, _} -> [align: "center"]
      {"th", [{"style", "text-align: right;"}], _, _} -> [align: "right"]
      {"td", [{"style", "text-align: left;"}], _, _} -> []
      {"td", [{"style", "text-align: center;"}], _, _} -> [align: "center"]
      {"td", [{"style", "text-align: right;"}], _, _} -> [align: "right"]
      {"img", [{"src", _link}, {"alt", alt}], _, _} -> [alt: alt]
      _any -> []
    end
  end
end
